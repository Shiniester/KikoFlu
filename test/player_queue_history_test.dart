import 'dart:async';

import 'package:flutter/material.dart';
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
const _history = PlaybackSessionSnapshot(
  queue: _historyTracks,
  currentIndex: 0,
  position: Duration(seconds: 37),
  ownerKey: 'https://example.invalid\nlistener',
  markingQueueId: 'historical-queue',
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  for (final size in [const Size(390, 844), const Size(1100, 800)]) {
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
      final header = tester.getRect(
        find.byKey(const ValueKey('player-queue-browser-header')),
      );
      final trackPosition = tester.getRect(
        find.byKey(const ValueKey('player-queue-current-track-position')),
      );
      final clear = tester.getRect(find.text('Clear'));
      expect(trackPosition.right, lessThan(header.center.dx));
      expect(clear.left, greaterThan(header.center.dx));
      expect(trackPosition.center.dy, closeTo(clear.center.dy, .01));
      final labels = S.of(tester.element(find.byType(PlayerQueueBrowser)));
      expect(find.text(labels.queueBrowserPagePosition(2, 2)), findsOneWidget);

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
      expect(find.text(labels.queueBrowserPagePosition(1, 2)), findsOneWidget);
      expect(find.text('0 / 2'), findsOneWidget);
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

    testWidgets(
      'queue swipes switch instantly without side boundaries at $size',
      (tester) async {
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
        final bounds = tester.getRect(find.byType(PlayerQueueSurface));
        final available = tester.getRect(
          find.byKey(const ValueKey('player-queue-pane')),
        );
        expect(bounds.left, closeTo(available.left, .01));
        expect(bounds.right, closeTo(available.right, .01));
        for (var page = 0; page < 2; page++) {
          final outgoingPage = page == 0
              ? find.byType(PlayerQueueSurface)
              : find.byKey(const ValueKey('player-queue-history-page-0'));
          final incomingPage = find.byKey(
            ValueKey('player-queue-history-page-$page'),
          );
          final gesture = await tester.startGesture(
            tester.getCenter(contentFinder),
          );
          await gesture.moveBy(const Offset(24, 0));
          await tester.pump();
          for (var step = 0; step < 3; step++) {
            await gesture.moveBy(Offset(bounds.width / 4, 0));
            await tester.pump();

            expect(tester.getRect(outgoingPage), bounds);
            expect(incomingPage, findsNothing);
          }
          await gesture.up();
          await tester.pump();
          expect(outgoingPage, findsNothing);
          expect(tester.getRect(incomingPage), bounds);
          expect(find.text('0 / ${page == 0 ? 2 : 1}'), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 150));
          expect(tester.getRect(incomingPage), bounds);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'selecting history restores its owning queue and selected index',
    (tester) async {
      final actions = _QueueActions();
      await _pumpQueue(tester, actions: actions, initialHistory: true);

      await tester.tap(
        find.byKey(const ValueKey('player-queue-history-track-history-second')),
      );
      await tester.pumpAndSettle();

      expect(actions.restored, [(_history, 1)]);
      expect(actions.skipped, isEmpty);
      expect(find.byType(PlayerQueueBrowser), findsOneWidget);
      expect(find.byType(PlayerQueueSurface), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-queue-history-page-0')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(find.text(_liveTrack.title).hitTestable(), findsWidgets);
    expect(actions.restored, isEmpty);
    expect(actions.skipped, isEmpty);
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
    expect(find.text('0 / 2'), findsOneWidget);
    final clearButton = find.byKey(const ValueKey('player-queue-clear-button'));
    await tester.tap(clearButton);
    await tester.pumpAndSettle();
    expect(find.text('Clear this historical playback queue?'), findsOneWidget);
    expect(actions.cleared, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(actions.cleared, isEmpty);
    expect(find.text('0 / 2'), findsOneWidget);

    await tester.tap(clearButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(actions.cleared, [_history]);
    expect(actions.currentCleared, 0);
    expect(actions.restored, isEmpty);
    expect(actions.skipped, isEmpty);
    expect(find.byType(PlayerQueueSurface), findsOneWidget);
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
    expect(find.text('0 / 2'), findsOneWidget);
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
  Stream<AudioTrack?>? currentTrackStream,
  Stream<List<AudioTrack>>? queueStream,
  Stream<List<PlaybackSessionSnapshot>>? historyStream,
  Widget? screen,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentTrackProvider.overrideWith((ref) async* {
          yield liveTrack;
          if (currentTrackStream != null) yield* currentTrackStream;
        }),
        queueProvider.overrideWith((ref) async* {
          yield [if (liveTrack != null) liveTrack];
          if (queueStream != null) yield* queueStream;
        }),
        historicalQueuesProvider.overrideWith((ref) async* {
          yield [_history];
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
        home:
            screen ??
            Scaffold(
              body: PlayerQueueBrowser(
                initialQueueHistory: initialHistory,
                showPageButtons: size.width >= 840,
                onClear: () async {
                  actions.currentCleared++;
                },
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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_slice.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_slice_presentation_provider.dart';
import 'package:kikoeru_flutter/src/providers/artwork_theme_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_cache_downloader.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/audio_slice_store.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:kikoeru_flutter/src/widgets/player/lyric_display_widget.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_controls_widget.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_slice_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_latest_request_test.dart'
    show ControlledPlayer, MemorySessionStore, until;

const _track = AudioTrack(
  id: 'slice-ui-track',
  hash: 'slice-ui-hash',
  workId: 42,
  title: 'Slice test track',
  url: 'https://example.invalid/slice-ui.mp3',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ControlledPlayer player;
  late AudioPlayerService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  Future<void> createService() async {
    player = ControlledPlayer();
    service = AudioPlayerService.forTesting(
      player,
      sessionStore: MemorySessionStore(),
      sliceStore: _MemorySliceStore(),
      cacheDownloader: _NoCacheDownloader(),
    );
    await service.updateQueue(const [_track], autoplay: false);
    addTearDown(() async => service.dispose());
  }

  test('slice time input round trips subsecond and hour positions', () {
    for (final milliseconds in [0, 1250, 90345, 3723004]) {
      expect(
        parseAudioSliceTime(formatAudioSliceTime(milliseconds)),
        milliseconds,
      );
    }
    expect(parseAudioSliceTime('1:02:03.004'), 3723004);
    expect(parseAudioSliceTime('90:00.5'), 5400500);
    for (final invalid in ['-01:00', '00:60', '1:60:00', '00:00.1234', 'abc']) {
      expect(parseAudioSliceTime(invalid), isNull);
    }
  });

  testWidgets('two cuts save a slice and cancel removes an unfinished start', (
    tester,
  ) async {
    await tester.runAsync(createService);
    await _pumpControls(tester, service, const Size(390, 844));
    final cut = find.byKey(const ValueKey('player-slice-cut-button'));
    player.position = const Duration(seconds: 20);
    await tester.runAsync(() => tester.tap(cut));
    await tester.pumpAndSettle();
    expect(service.sliceState.pendingStartMs, 20000);
    expect(find.byTooltip('Mark slice end'), findsOneWidget);

    player.position = const Duration(seconds: 120);
    await tester.runAsync(() => tester.tap(cut));
    await tester.pumpAndSettle();
    expect(service.sliceState.slices, const [
      AudioSlice(startMs: 20000, endMs: 120000),
    ]);
    player.position = const Duration(seconds: 150);
    await tester.runAsync(() => tester.tap(cut));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-slice-manager-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cancel slice start'));
    await tester.pumpAndSettle();
    expect(service.sliceState.pendingStartMs, isNull);
    expect(find.text('00:20.000 – 02:00.000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cut button uses the supplied subtitle timestamps', (
    tester,
  ) async {
    await tester.runAsync(createService);
    player.position = const Duration(seconds: 90);
    await _pumpControls(
      tester,
      service,
      const Size(390, 844),
      slicePosition: const Duration(seconds: 10),
    );
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('player-slice-cut-button'))),
    );
    await tester.pumpAndSettle();
    expect(service.sliceState.pendingStartMs, 10000);

    await _pumpControls(
      tester,
      service,
      const Size(390, 844),
      slicePosition: const Duration(seconds: 30),
    );
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('player-slice-cut-button'))),
    );
    await tester.pumpAndSettle();

    expect(service.sliceState.slices.single.startMs, 10000);
    expect(service.sliceState.slices.single.endMs, 30000);
    expect(player.position, const Duration(seconds: 90));
  });

  testWidgets(
    'subtitle cuts wait for the new track subtitles after switching',
    (tester) async {
      await tester.runAsync(createService);
      final directory = Directory.systemTemp.createTempSync(
        'subtitle-cut-track-',
      );
      final first = File('${directory.path}/first.lrc')
        ..writeAsStringSync('[00:10.00]old subtitle');
      final second = File('${directory.path}/second.lrc')
        ..writeAsStringSync('[00:20.00]new subtitle');
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => directory.delete(recursive: true));
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [audioPlayerServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(
              body: FullLyricDisplay(
                isPortrait: true,
                showPlaybackLineControls: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FullLyricDisplay)),
        listen: false,
      );
      final lyrics = container.read(lyricControllerProvider.notifier);
      await tester.runAsync(() => container.read(currentTrackProvider.future));
      await tester.runAsync(() => lyrics.loadLyricFromLocalFile(first.path));
      await tester.pumpAndSettle();
      final cut = find.byKey(const ValueKey('player-slice-cut-button'));
      final previousCut = tester.widget<IconButton>(cut).onPressed;
      expect(previousCut, isNotNull);

      await tester.runAsync(
        () => service.updateQueue(const [
          AudioTrack(
            id: 'next-track',
            hash: 'next-track',
            workId: 42,
            title: 'Next track',
            url: 'https://example.invalid/next.mp3',
          ),
        ], autoplay: false),
      );
      await tester.pumpAndSettle();
      expect(service.isTrackLoading, isFalse);
      expect(container.read(lyricControllerProvider).isLoading, isFalse);
      expect(
        container.read(lyricControllerProvider).lyrics.single.text,
        'old subtitle',
      );
      expect(tester.widget<IconButton>(cut).onPressed, isNull);

      await tester.runAsync(() async => previousCut!());
      await tester.pumpAndSettle();
      expect(service.sliceState.pendingStartMs, isNull);

      await tester.runAsync(() => lyrics.loadLyricFromLocalFile(second.path));
      lyrics.clearTranslation();
      lyrics.adjustTimelineOffset(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(cut).onPressed, isNotNull);
      await tester.runAsync(() => tester.tap(cut));
      await tester.pumpAndSettle();
      expect(service.sliceState.pendingStartMs, 22000);
      expect(player.position, Duration.zero);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('manager timeline seeks gaps and links slice selection to rows', (
    tester,
  ) async {
    await tester.runAsync(createService);
    final trackKey = service.sliceState.trackKey!;
    final slices = [
      for (var index = 0; index < 12; index++)
        AudioSlice(
          startMs: 10000 + index * 20000,
          endMs: 20000 + index * 20000,
        ),
    ];
    await tester.runAsync(() async {
      for (final slice in slices) {
        await service.saveSlice(trackKey: trackKey, slice: slice);
      }
    });
    await _pumpControls(tester, service, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('player-slice-manager-button')));
    await tester.pumpAndSettle();

    final timeline = find.byKey(
      const ValueKey('audio-slice-manager-timeline-slider'),
    );
    final timelineTheme = tester.widget<SliderTheme>(
      find.ancestor(of: timeline, matching: find.byType(SliderTheme)).first,
    );
    expect(timelineTheme.data.thumbShape, same(SliderComponentShape.noThumb));
    final container = ProviderScope.containerOf(
      tester.element(timeline),
      listen: false,
    );
    final firstRow = find.byKey(const ValueKey('audio-slice-10000-20000'));
    await tester.fling(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -1600),
      3000,
    );
    await tester.pumpAndSettle();
    expect(firstRow.hitTestable(), findsNothing);

    await tester.runAsync(
      () => tester.tapAt(_timelinePosition(tester, timeline, 15000 / 300000)),
    );
    await tester.runAsync(
      () => until(() => player.position == const Duration(seconds: 15)),
    );
    await tester.pumpAndSettle();
    expect(container.read(audioSliceSelectionProvider)?.slice, slices.first);
    expect(firstRow.hitTestable(), findsOneWidget);

    await tester.runAsync(
      () => tester.tapAt(_timelinePosition(tester, timeline, 25000 / 300000)),
    );
    await tester.runAsync(
      () => until(() => player.position == const Duration(seconds: 25)),
    );
    player.positions.add(player.position);
    await tester.pumpAndSettle();
    expect(container.read(audioSliceSelectionProvider), isNull);
    expect(find.text('Position'), findsOneWidget);
    expect(find.text('Current slice'), findsNothing);

    final secondRow = find.byKey(const ValueKey('audio-slice-30000-40000'));
    await tester.pump();
    final drag = await tester.startGesture(
      _timelinePosition(tester, timeline, 5000 / 300000),
    );
    await drag.moveTo(_timelinePosition(tester, timeline, 35000 / 300000));
    await tester.pump();
    await tester.runAsync(drag.up);
    await tester.runAsync(
      () => until(() => player.position == const Duration(seconds: 35)),
    );
    await tester.pumpAndSettle();
    expect(container.read(audioSliceSelectionProvider)?.slice, slices[1]);

    await tester.ensureVisible(secondRow);
    await tester.runAsync(() => tester.tap(secondRow));
    await tester.runAsync(
      () => until(() => player.position == const Duration(seconds: 30)),
    );
    expect(container.read(audioSliceSelectionProvider)?.slice, slices[1]);

    player.position = const Duration(seconds: 15);
    player.positions.add(player.position);
    await tester.pump();
    final progress = find.byKey(const ValueKey('player-progress-slider'));
    final progressTheme = tester.widget<SliderTheme>(
      find.ancestor(of: progress, matching: find.byType(SliderTheme)).first,
    );
    final progressShape =
        progressTheme.data.trackShape! as PlayerUniformSliderTrackShape;
    expect(container.read(activeAudioSliceProvider), slices.first);
    expect(progressShape.selectedSlice, slices[1]);
    expect(player.playing, isFalse);
    expect(tester.widget<ListTile>(firstRow).selected, isFalse);
    expect(tester.widget<ListTile>(secondRow).selected, isTrue);
    expect(
      find.descendant(of: firstRow, matching: find.text('Current slice')),
      findsOneWidget,
    );
    await tester.runAsync(service.play);
    await tester.pumpAndSettle();
    expect(container.read(activeAudioSliceProvider), slices.first);
    await tester.runAsync(service.pause);
    await tester.pumpAndSettle();
    expect(container.read(activeAudioSliceProvider), slices.first);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(container.read(audioSliceSelectionProvider), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'progress long press maps padded track endpoints to slice times',
    (tester) async {
      await tester.runAsync(createService);
      final trackKey = service.sliceState.trackKey!;
      const slices = [
        AudioSlice(startMs: 30000, endMs: 31000),
        AudioSlice(startMs: 296000, endMs: 300000),
      ];
      await tester.runAsync(() async {
        for (final slice in slices) {
          await service.saveSlice(trackKey: trackKey, slice: slice);
        }
      });
      await _pumpControls(
        tester,
        service,
        const Size(390, 844),
        onSeekEnd: (_) {},
      );

      final target = find.byKey(
        const ValueKey('player-progress-gesture-target'),
      );
      final rect = tester.getRect(target);
      final container = ProviderScope.containerOf(
        tester.element(target),
        listen: false,
      );
      Future<void> expectInitialSliceAt(
        double fraction,
        AudioSlice? slice,
      ) async {
        await tester.longPressAt(
          Offset(
            rect.left +
                PlayerUniformSliderTrackShape.thumbRadius +
                (rect.width - PlayerUniformSliderTrackShape.thumbRadius * 2) *
                    fraction,
            rect.center.dy,
          ),
        );
        await tester.pumpAndSettle();
        expect(container.read(audioSliceSelectionProvider)?.slice, slice);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
      }

      await expectInitialSliceAt(30500 / 300000, slices.first);
      await expectInitialSliceAt(298000 / 300000, slices.last);
      await expectInitialSliceAt(0, null);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manager selection does not return after switching away and back',
    (tester) async {
      await tester.runAsync(createService);
      final trackKey = service.sliceState.trackKey!;
      const slice = AudioSlice(startMs: 10000, endMs: 20000);
      await tester.runAsync(
        () => service.saveSlice(trackKey: trackKey, slice: slice),
      );
      await _pumpControls(tester, service, const Size(390, 844));
      await tester.tap(
        find.byKey(const ValueKey('player-slice-manager-button')),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(const ValueKey('audio-slice-10000-20000'));
      final container = ProviderScope.containerOf(
        tester.element(row),
        listen: false,
      );
      await tester.runAsync(() => tester.tap(row));
      await tester.pumpAndSettle();
      expect(container.read(audioSliceSelectionProvider)?.slice, slice);

      final nextTrack = _track.copyWith(
        id: 'slice-ui-next-track',
        hash: 'slice-ui-next-hash',
        url: 'https://example.invalid/slice-ui-next.mp3',
      );
      await tester.runAsync(
        () => service.updateQueue([_track, nextTrack], autoplay: false),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await service.skipToNext();
        await until(() => service.currentTrack?.id == nextTrack.id);
      });
      await tester.pumpAndSettle();
      expect(container.read(audioSliceSelectionProvider), isNull);
      await tester.runAsync(() async {
        await service.skipToPrevious();
        await until(() => service.currentTrack?.id == _track.id);
      });
      await tester.pumpAndSettle();
      expect(service.sliceState.trackKey, trackKey);
      expect(container.read(audioSliceSelectionProvider), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editing does not restore selection after switching away and back',
    (tester) async {
      await tester.runAsync(createService);
      final trackKey = service.sliceState.trackKey!;
      const original = AudioSlice(startMs: 10000, endMs: 20000);
      await tester.runAsync(
        () => service.saveSlice(trackKey: trackKey, slice: original),
      );
      await _pumpControls(tester, service, const Size(390, 844));
      await tester.tap(
        find.byKey(const ValueKey('player-slice-manager-button')),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(const ValueKey('audio-slice-10000-20000'));
      final container = ProviderScope.containerOf(
        tester.element(row),
        listen: false,
      );
      await tester.runAsync(() => tester.tap(row));
      await tester.pumpAndSettle();
      expect(container.read(audioSliceSelectionProvider)?.slice, original);
      final menu = find.byType(PopupMenuButton<String>).first;
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(container.read(audioSliceSelectionProvider)?.slice, original);

      final start = find.byKey(const ValueKey('audio-slice-start-time'));
      final end = find.byKey(const ValueKey('audio-slice-end-time'));
      await tester.ensureVisible(start);
      await tester.enterText(start, '00:12.345');
      await tester.ensureVisible(end);
      await tester.enterText(end, '00:25.000');

      final nextTrack = _track.copyWith(
        id: 'slice-ui-edit-next-track',
        hash: 'slice-ui-edit-next-hash',
        url: 'https://example.invalid/slice-ui-edit-next.mp3',
      );
      await tester.runAsync(
        () => service.updateQueue([_track, nextTrack], autoplay: false),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await service.skipToNext();
        await until(() => service.currentTrack?.id == nextTrack.id);
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await service.skipToPrevious();
        await until(() => service.currentTrack?.id == _track.id);
      });
      await tester.pumpAndSettle();

      await tester.runAsync(() => tester.tap(find.text('Save')));
      await tester.pumpAndSettle();
      expect(service.sliceState.slices, const [
        AudioSlice(startMs: 12345, endMs: 25000),
      ]);
      expect(container.read(audioSliceSelectionProvider), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('timeline drag from another track cannot seek the new track', (
    tester,
  ) async {
    await tester.runAsync(createService);
    final trackKey = service.sliceState.trackKey!;
    await tester.runAsync(
      () => service.saveSlice(
        trackKey: trackKey,
        slice: const AudioSlice(startMs: 10000, endMs: 20000),
      ),
    );
    final nextTrack = _track.copyWith(
      id: 'slice-ui-drag-next-track',
      hash: 'slice-ui-drag-next-hash',
      url: 'https://example.invalid/slice-ui-drag-next.mp3',
    );
    await tester.runAsync(
      () => service.updateQueue([_track, nextTrack], autoplay: false),
    );
    await _pumpControls(tester, service, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('player-slice-manager-button')));
    await tester.pumpAndSettle();
    final timeline = find.byKey(
      const ValueKey('audio-slice-manager-timeline-slider'),
    );

    final gesture = await tester.startGesture(
      _timelinePosition(tester, timeline, 15000 / 300000),
    );
    await gesture.moveTo(_timelinePosition(tester, timeline, 25000 / 300000));
    await tester.pump();
    await tester.runAsync(() async {
      await service.skipToNext();
      await until(() => service.currentTrack?.id == nextTrack.id);
    });
    await tester.pumpAndSettle();
    final seekCount = player.seeks.length;
    await tester.runAsync(gesture.up);
    await tester.pumpAndSettle();

    expect(service.currentTrack?.id, nextTrack.id);
    expect(player.seeks, hasLength(seekCount));
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing manager during a seek clears timeline scrubbing', (
    tester,
  ) async {
    await tester.runAsync(createService);
    final trackKey = service.sliceState.trackKey!;
    await tester.runAsync(
      () => service.saveSlice(
        trackKey: trackKey,
        slice: const AudioSlice(startMs: 10000, endMs: 20000),
      ),
    );
    await _pumpControls(tester, service, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('player-slice-manager-button')));
    await tester.pumpAndSettle();
    final timeline = find.byKey(
      const ValueKey('audio-slice-manager-timeline-slider'),
    );
    player.holdNextSeek = true;
    final gesture = await tester.startGesture(
      _timelinePosition(tester, timeline, 15000 / 300000),
    );
    await gesture.moveTo(_timelinePosition(tester, timeline, 25000 / 300000));
    await tester.pump();
    await tester.runAsync(gesture.up);
    await tester.runAsync(() => until(() => player.pendingSeek != null));

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    player.finishSeek();
    await tester.runAsync(() => until(() => player.pendingSeek == null));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor shortcuts step, clamp, and keep edits as a draft', (
    tester,
  ) async {
    await tester.runAsync(createService);
    final trackKey = service.sliceState.trackKey!;
    const original = AudioSlice(startMs: 20000, endMs: 120000);
    await tester.runAsync(
      () => service.saveSlice(trackKey: trackKey, slice: original),
    );
    await _pumpControls(tester, service, const Size(390, 844));
    await _openSliceEditor(tester);

    final start = find.byKey(const ValueKey('audio-slice-start-time'));
    final end = find.byKey(const ValueKey('audio-slice-end-time'));
    await tester.ensureVisible(start);
    await tester.enterText(start, '00:00.100');
    await _tapEndpointAction(tester, 'Start time', 0);
    expect(tester.widget<TextField>(start).controller!.text, '00:00.000');
    await _tapEndpointAction(tester, 'Start time', 3);
    expect(tester.widget<TextField>(start).controller!.text, '00:00.200');
    await _tapEndpointAction(tester, 'Start time', 4);
    expect(tester.widget<TextField>(start).controller!.text, '00:01.200');
    await _tapEndpointAction(tester, 'Start time', 5);
    expect(tester.widget<TextField>(start).controller!.text, '00:06.200');
    await _tapEndpointAction(tester, 'Start time', 1);
    await _tapEndpointAction(tester, 'Start time', 2);
    expect(tester.widget<TextField>(start).controller!.text, '00:00.200');

    await tester.ensureVisible(end);
    await tester.enterText(end, '00:10.000');
    await _tapEndpointAction(tester, 'End time', 3);
    expect(tester.widget<TextField>(end).controller!.text, '00:10.200');
    await _tapEndpointAction(tester, 'End time', 0);
    expect(tester.widget<TextField>(end).controller!.text, '00:10.000');
    await tester.ensureVisible(end);
    await tester.enterText(end, '04:59.900');
    await _tapEndpointAction(tester, 'End time', 3);
    expect(tester.widget<TextField>(end).controller!.text, '05:00.000');

    player.position = const Duration(milliseconds: 12345);
    await _tapEndpointAction(tester, 'Start time', 6);
    await _tapEndpointAction(tester, 'End time', 6);
    expect(tester.widget<TextField>(start).controller!.text, '00:12.345');
    expect(tester.widget<TextField>(end).controller!.text, '00:12.345');
    await _tapEndpointAction(tester, 'Start time', 7);
    await _tapEndpointAction(tester, 'End time', 7);
    expect(tester.widget<TextField>(start).controller!.text, '00:00.000');
    expect(tester.widget<TextField>(end).controller!.text, '00:00.000');
    await _tapEndpointAction(tester, 'Start time', 8);
    await _tapEndpointAction(tester, 'End time', 8);
    expect(tester.widget<TextField>(start).controller!.text, '05:00.000');
    expect(tester.widget<TextField>(end).controller!.text, '05:00.000');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.sliceState.slices, [original]);

    await _openSliceEditor(tester, managerAlreadyOpen: true);
    await _tapEndpointAction(tester, 'Start time', 6);
    await _tapEndpointAction(tester, 'End time', 8);
    await tester.runAsync(() => tester.tap(find.text('Save')));
    await tester.pumpAndSettle();
    expect(service.sliceState.slices, const [
      AudioSlice(startMs: 12345, endMs: 300000),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor reports invalid steps and preserves overlap validation', (
    tester,
  ) async {
    await tester.runAsync(createService);
    final trackKey = service.sliceState.trackKey!;
    const first = AudioSlice(startMs: 10000, endMs: 20000);
    const second = AudioSlice(startMs: 30000, endMs: 40000);
    await tester.runAsync(() async {
      await service.saveSlice(trackKey: trackKey, slice: first);
      await service.saveSlice(trackKey: trackKey, slice: second);
    });
    await _pumpControls(tester, service, const Size(390, 844));
    await _openSliceEditor(tester);

    final start = find.byKey(const ValueKey('audio-slice-start-time'));
    final end = find.byKey(const ValueKey('audio-slice-end-time'));
    await tester.ensureVisible(start);
    await tester.enterText(start, 'invalid');
    await _tapEndpointAction(tester, 'Start time', 0);
    expect(find.text('Enter a valid time, such as 00:30.000.'), findsOneWidget);

    await tester.ensureVisible(start);
    await tester.enterText(start, '00:35.000');
    await tester.ensureVisible(end);
    await tester.enterText(end, '00:37.000');
    await tester.runAsync(() => tester.tap(find.text('Save')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Could not save the slice. Check the times and overlapping slices, then try again.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('audio-slice-range-editor')),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.sliceState.slices, const [first, second]);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(390, 844),
    const Size(1100, 700),
    const Size(800, 360),
  ]) {
    testWidgets('manage, drag, edit, and preview slices at $size', (
      tester,
    ) async {
      await tester.runAsync(createService);
      final trackKey = service.sliceState.trackKey!;
      await tester.runAsync(
        () => service.saveSlice(
          trackKey: trackKey,
          slice: const AudioSlice(startMs: 20000, endMs: 120000),
        ),
      );
      await _pumpControls(tester, service, size);
      await tester.tap(
        find.byKey(const ValueKey('player-slice-manager-button')),
      );
      await tester.pumpAndSettle();
      final manager = find.byType(PopupMenuButton<String>);
      await tester.ensureVisible(manager);
      final container = ProviderScope.containerOf(
        tester.element(manager),
        listen: false,
      );
      final sliceRow = find.byKey(const ValueKey('audio-slice-20000-120000'));
      await tester.ensureVisible(sliceRow);
      await tester.runAsync(() => tester.tap(sliceRow));
      await tester.pumpAndSettle();
      expect(
        container.read(audioSliceSelectionProvider)?.slice,
        const AudioSlice(startMs: 20000, endMs: 120000),
      );
      await tester.tap(manager);
      await tester.pumpAndSettle();
      expect(
        container.read(audioSliceSelectionProvider)?.slice,
        const AudioSlice(startMs: 20000, endMs: 120000),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      final editor = find.byKey(const ValueKey('audio-slice-range-editor'));
      final rect = tester.getRect(editor);
      final endThumb = Offset(
        rect.left + 24 + (rect.width - 48) * 0.4,
        rect.center.dy,
      );
      await tester.dragFrom(endThumb, const Offset(24, 0));
      await tester.pumpAndSettle();
      expect(
        tester.widget<RangeSlider>(editor).values.end,
        greaterThan(120000),
      );
      await tester.enterText(
        find.byKey(const ValueKey('audio-slice-start-time')),
        '00:25.250',
      );
      await tester.enterText(
        find.byKey(const ValueKey('audio-slice-end-time')),
        '02:30.500',
      );
      await tester.runAsync(() => tester.tap(find.text('Save')));
      await tester.pumpAndSettle();
      expect(service.sliceState.slices, const [
        AudioSlice(startMs: 25250, endMs: 150500),
      ]);
      expect(
        container.read(audioSliceSelectionProvider)?.slice,
        const AudioSlice(startMs: 25250, endMs: 150500),
      );
      expect(find.text('00:25.250 – 02:30.500'), findsOneWidget);

      final onlySlicesSwitch = find.byKey(
        const ValueKey('player-only-slices-switch'),
      );
      await tester.ensureVisible(onlySlicesSwitch);
      await tester.pumpAndSettle();
      await tester.tap(onlySlicesSwitch);
      await tester.pumpAndSettle();
      expect(service.sliceState.onlySlices, isTrue);
      for (final key in [
        'player-progress-slider',
        'audio-slice-manager-timeline-slider',
      ]) {
        final theme = tester.widget<SliderTheme>(
          find
              .ancestor(
                of: find.byKey(ValueKey(key)),
                matching: find.byType(SliderTheme),
              )
              .first,
        );
        expect(
          (theme.data.trackShape! as PlayerUniformSliderTrackShape).onlySlices,
          isTrue,
        );
      }
      await tester.ensureVisible(find.byTooltip('Preview slice'));
      await tester.runAsync(() => tester.tap(find.byTooltip('Preview slice')));
      await tester.pumpAndSettle();
      expect(service.sliceState.preview, service.sliceState.slices.single);
      expect(player.playing, isTrue);
      await tester.runAsync(() => tester.tap(find.byTooltip('Stop preview')));
      await tester.pumpAndSettle();
      expect(service.sliceState.preview, isNull);
      expect(player.playing, isFalse);
      await tester.ensureVisible(find.byType(PopupMenuButton<String>));
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Delete')));
      await tester.pumpAndSettle();
      // The modal finishes in fake time before persistence resumes in real time.
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      expect(service.sliceState.slices, isEmpty);
      expect(container.read(audioSliceSelectionProvider), isNull);
      expect(
        find.text('No slices yet. Mark a start and end to create a slice.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('clear slices requires confirmation', (tester) async {
    await tester.runAsync(createService);
    await tester.runAsync(() async {
      for (final slice in const [
        AudioSlice(startMs: 10000, endMs: 20000),
        AudioSlice(startMs: 30000, endMs: 40000),
      ]) {
        await service.saveSlice(
          trackKey: service.sliceState.trackKey!,
          slice: slice,
        );
      }
    });
    await _pumpControls(tester, service, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('player-slice-manager-button')));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('audio-slice-10000-20000'));
    final container = ProviderScope.containerOf(
      tester.element(row),
      listen: false,
    );
    await tester.runAsync(() => tester.tap(row));
    await tester.pumpAndSettle();
    expect(container.read(audioSliceSelectionProvider)?.slice, isNotNull);
    await tester.tap(find.text('Clear slices'));
    await tester.pumpAndSettle();
    expect(service.sliceState.slices, hasLength(2));
    await tester.runAsync(() => tester.tap(find.text('Clear')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(service.sliceState.slices, isEmpty);
    expect(container.read(audioSliceSelectionProvider), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('releasing a slice-boundary drag keeps the requested track', (
    tester,
  ) async {
    await tester.runAsync(createService);
    await tester.runAsync(() async {
      await service.updateQueue([
        _track,
        _track.copyWith(
          id: 'next-slice-ui-track',
          hash: 'next-slice-ui-hash',
          url: 'https://example.invalid/next-slice-ui.mp3',
        ),
      ]);
      await service.saveSlice(
        trackKey: service.sliceState.trackKey!,
        slice: const AudioSlice(startMs: 10000, endMs: 120000),
      );
      service.setOnlySlices(true);
      await service.play();
    });
    await _pumpControls(tester, service, const Size(390, 844));
    final slider = find.byKey(const ValueKey('player-progress-slider'));
    final rect = tester.getRect(slider);
    final gesture = await tester.startGesture(
      Offset(rect.left + rect.width * 0.2, rect.center.dy),
    );
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    player.position = const Duration(milliseconds: 120001);
    player.positions.add(player.position);
    await tester.pump();
    expect(service.currentTrack, _track);

    await tester.runAsync(gesture.up);
    await tester.runAsync(() => until(() => !service.isTrackLoading));
    await tester.pumpAndSettle();

    expect(service.currentTrack, _track);
    expect(player.position, greaterThan(const Duration(seconds: 10)));
    expect(player.position, lessThan(const Duration(seconds: 120)));
    expect(player.playing, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mini player displays slices and preserves paused seeking', (
    tester,
  ) async {
    await tester.runAsync(createService);
    await tester.runAsync(
      () => service.saveSlice(
        trackKey: service.sliceState.trackKey!,
        slice: const AudioSlice(startMs: 20000, endMs: 120000),
      ),
    );
    service.setOnlySlices(true);
    await _pumpControls(tester, service, const Size(390, 844), miniOnly: true);
    final slider = find.byKey(const ValueKey('mini-player-progress-slider'));
    final theme = tester.widget<SliderTheme>(
      find.ancestor(of: slider, matching: find.byType(SliderTheme)).first,
    );
    expect(theme.data.trackHeight, 4);
    expect(tester.getSize(slider).height, 12);
    final thumbShape = theme.data.thumbShape! as RoundSliderThumbShape;
    expect(thumbShape.enabledThumbRadius, 5);
    expect(thumbShape.disabledThumbRadius, 5);
    final sliceColor =
        (theme.data.trackShape! as PlayerUniformSliderTrackShape).sliceColor;
    final primaryColor = Theme.of(tester.element(slider)).colorScheme.primary;
    expect(theme.data.thumbColor, primaryColor);
    expect(
      (HSLColor.fromColor(sliceColor).hue -
              HSLColor.fromColor(primaryColor).hue)
          .abs(),
      inInclusiveRange(120, 240),
    );
    expect(
      (theme.data.trackShape! as PlayerUniformSliderTrackShape).slices,
      service.sliceState.slices,
    );
    expect(
      (theme.data.trackShape! as PlayerUniformSliderTrackShape).onlySlices,
      isTrue,
    );
    final container = ProviderScope.containerOf(
      tester.element(slider),
      listen: false,
    );
    container
        .read(audioSliceSelectionProvider.notifier)
        .state = AudioSliceSelection(
      trackKey: service.sliceState.trackKey!,
      slice: service.sliceState.slices.single,
    );
    player.position = const Duration(seconds: 30);
    player.positions.add(player.position);
    await tester.pump();
    final updatedTheme = tester.widget<SliderTheme>(
      find.ancestor(of: slider, matching: find.byType(SliderTheme)).first,
    );
    final shape =
        updatedTheme.data.trackShape! as PlayerUniformSliderTrackShape;
    expect(
      container.read(activeAudioSliceProvider),
      service.sliceState.slices.single,
    );
    expect(shape.selectedSlice, service.sliceState.slices.single);
    expect(player.playing, isFalse);
    expect(find.byKey(const ValueKey('player-slice-cut-button')), findsNothing);
    expect(updatedTheme.data.thumbColor, sliceColor);

    final sliderRect = tester.getRect(slider);
    final trackLeft =
        sliderRect.left + PlayerUniformSliderTrackShape.thumbRadius;
    final trackWidth =
        sliderRect.width - PlayerUniformSliderTrackShape.thumbRadius * 2;
    Offset trackPoint(double fraction) =>
        Offset(trackLeft + trackWidth * fraction, sliderRect.center.dy);
    final drag = await tester.startGesture(trackPoint(0.1));
    await drag.moveTo(trackPoint(0.7));
    await tester.pump();
    final outsideTheme = tester.widget<SliderTheme>(
      find.ancestor(of: slider, matching: find.byType(SliderTheme)).first,
    );
    expect(outsideTheme.data.thumbColor, primaryColor);
    expect(tester.widget<Slider>(slider).value, closeTo(0.7, 0.01));

    await drag.moveTo(trackPoint(0.3));
    await tester.pump();
    final insideTheme = tester.widget<SliderTheme>(
      find.ancestor(of: slider, matching: find.byType(SliderTheme)).first,
    );
    expect(insideTheme.data.thumbColor, sliceColor);
    expect(tester.widget<Slider>(slider).value, closeTo(0.3, 0.01));
    await tester.runAsync(drag.up);
    await tester.pumpAndSettle();

    await tester.runAsync(() => tester.tapAt(trackPoint(0.25)));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => until(() => player.position == const Duration(seconds: 75)),
    );
    await tester.runAsync(
      () => tester.tapAt(
        Offset(
          sliderRect.right - PlayerUniformSliderTrackShape.thumbRadius,
          sliderRect.center.dy,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => until(() => player.position == const Duration(minutes: 5)),
    );
    expect(player.position, const Duration(minutes: 5));
    expect(player.playing, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final locale in [const Locale('zh'), const Locale('ja')]) {
    testWidgets('large text keeps slice management reachable in $locale', (
      tester,
    ) async {
      await tester.runAsync(createService);
      await tester.runAsync(() async {
        for (final slice in const [
          AudioSlice(startMs: 10000, endMs: 20000),
          AudioSlice(startMs: 30000, endMs: 40000),
        ]) {
          await service.saveSlice(
            trackKey: service.sliceState.trackKey!,
            slice: slice,
          );
        }
        player.position = const Duration(seconds: 200);
        await service.markSlice();
      });
      await _pumpControls(
        tester,
        service,
        const Size(800, 360),
        locale: locale,
        textScale: 2,
      );
      await tester.tap(
        find.byKey(const ValueKey('player-slice-manager-button')),
      );
      await tester.pumpAndSettle();
      final menu = find.byType(PopupMenuButton<String>).last;
      await tester.ensureVisible(menu);
      await tester.pumpAndSettle();
      expect(menu.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

Offset _timelinePosition(WidgetTester tester, Finder slider, double fraction) {
  final rect = tester.getRect(slider);
  return Offset(rect.left + 24 + (rect.width - 48) * fraction, rect.center.dy);
}

Future<void> _openSliceEditor(
  WidgetTester tester, {
  bool managerAlreadyOpen = false,
}) async {
  if (!managerAlreadyOpen) {
    await tester.tap(find.byKey(const ValueKey('player-slice-manager-button')));
    await tester.pumpAndSettle();
  }
  final menu = find.byType(PopupMenuButton<String>).first;
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit').first);
  await tester.pumpAndSettle();
}

Future<void> _tapEndpointAction(
  WidgetTester tester,
  String endpoint,
  int index,
) async {
  final action = find.byKey(ValueKey('audio-slice-action-$endpoint-$index'));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Future<void> _pumpControls(
  WidgetTester tester,
  AudioPlayerService service,
  Size size, {
  bool miniOnly = false,
  Duration? slicePosition,
  Locale locale = const Locale('en'),
  double textScale = 1,
  ValueChanged<double>? onSeekEnd,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        audioPlayerServiceProvider.overrideWithValue(service),
        themeArtworkDescriptorProvider.overrideWith((ref) => null),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: miniOnly
              ? null
              : Center(
                  child: SizedBox(
                    width: 520,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PlayerProgressSection(
                          isSeekingManually: false,
                          seekValue: 0,
                          onSeekChanged: (_) {},
                          onSeekEnd:
                              onSeekEnd ??
                              (value) => service.seek(
                                Duration(
                                  milliseconds: (value * 300000).round(),
                                ),
                              ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            PlayerSliceCutButton(
                              position: slicePosition,
                              trackKey: service.sliceState.trackKey,
                            ),
                            const PlayerSliceManagerButton(),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
          bottomNavigationBar: miniOnly ? const MiniPlayer() : null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _NoCacheDownloader extends AudioCacheDownloader {
  _NoCacheDownloader() : super(files: CacheService.audioCacheFiles);

  @override
  Future<bool> setTarget(AudioCacheRequest? request) async => false;
}

class _MemorySliceStore implements AudioSliceStore {
  final _slices = <String, List<AudioSlice>>{};

  @override
  Future<List<AudioSlice>> load(String trackKey) async =>
      List.of(_slices[trackKey] ?? const []);

  @override
  Future<bool> write(String trackKey, List<AudioSlice> slices) async {
    _slices[trackKey] = List.of(slices);
    return true;
  }

  @override
  Future<bool> clear(String trackKey) async {
    _slices.remove(trackKey);
    return true;
  }
}

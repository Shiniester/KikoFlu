import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_slice.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/artwork_theme_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_cache_downloader.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/audio_slice_store.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
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
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
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
      expect(find.text('00:25.250 – 02:30.500'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('player-only-slices-switch')));
      await tester.pumpAndSettle();
      expect(service.sliceState.onlySlices, isTrue);
      await tester.runAsync(() => tester.tap(find.byTooltip('Preview slice')));
      await tester.pumpAndSettle();
      expect(service.sliceState.preview, service.sliceState.slices.single);
      expect(player.playing, isTrue);
      await tester.runAsync(() => tester.tap(find.byTooltip('Stop preview')));
      await tester.pumpAndSettle();
      expect(service.sliceState.preview, isNull);
      expect(player.playing, isFalse);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Delete')));
      await tester.pumpAndSettle();
      // The modal finishes in fake time before persistence resumes in real time.
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      expect(service.sliceState.slices, isEmpty);
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
    await tester.tap(find.text('Clear slices'));
    await tester.pumpAndSettle();
    expect(service.sliceState.slices, hasLength(2));
    await tester.runAsync(() => tester.tap(find.text('Clear')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(service.sliceState.slices, isEmpty);
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
    expect(
      (theme.data.trackShape! as PlayerUniformSliderTrackShape).slices,
      service.sliceState.slices,
    );
    expect(find.byKey(const ValueKey('player-slice-cut-button')), findsNothing);
    await tester.runAsync(() => tester.tapAt(tester.getCenter(slider)));
    await tester.pumpAndSettle();
    expect(player.position, greaterThan(const Duration(seconds: 120)));
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

Future<void> _pumpControls(
  WidgetTester tester,
  AudioPlayerService service,
  Size size, {
  bool miniOnly = false,
  Locale locale = const Locale('en'),
  double textScale = 1,
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
                          onSeekEnd: (value) => service.seek(
                            Duration(milliseconds: (value * 300000).round()),
                          ),
                        ),
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            PlayerSliceCutButton(),
                            PlayerSliceManagerButton(),
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

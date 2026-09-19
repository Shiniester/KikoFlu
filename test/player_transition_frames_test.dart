import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_cover_widget.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_vertical_gestures.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/player_route_geometry.dart';

const track = AudioTrack(
  id: 'frames',
  title: 'Player transition',
  artist: 'Artist',
  url: 'https://example.invalid/audio.flac',
);

void main() {
  _surfaceRegressions();
  testWidgets('real player expansion keyframes', (tester) async {
    await pumpPlayer(tester);
    await tester.tap(find.byKey(const ValueKey('mini-player-upward-launcher')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await frame(tester, 'expand_80');
    await tester.pump(const Duration(milliseconds: 100));
    await frame(tester, 'expand_180');
    await tester.pump(const Duration(milliseconds: 120));
    await frame(tester, 'expand_300');
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('compact-player-pages'))),
    );
    await gesture.moveBy(const Offset(-20, 0));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    await frame(tester, 'page_partial');
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('interactive open reversal and handoff keyframes', (
    tester,
  ) async {
    await pumpPlayer(tester);
    final launcher = find.byKey(const ValueKey('mini-player-upward-launcher'));
    final sourceArtwork = tester.getRect(
      find.byKey(const ValueKey('mini-player-artwork-frame')),
    );
    final gesture = await tester.startGesture(tester.getCenter(launcher));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    _expectPreviewCover(tester, sourceArtwork);
    await frame(tester, 'drag_120');
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    _expectPreviewCover(tester, sourceArtwork);
    await frame(tester, 'drag_reverse');
    await gesture.cancel();
    await tester.pumpAndSettle();
    final opening = await tester.startGesture(tester.getCenter(launcher));
    for (var step = 0; step < 14; step++) {
      await opening.moveBy(const Offset(0, -16));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await opening.up();
    await tester.pump(const Duration(milliseconds: 16));
    _expectPreviewCover(tester, sourceArtwork);
    await frame(tester, 'handoff');
    await tester.pumpAndSettle();
  });
}

Future<void> frame(WidgetTester tester, String name) async {
  await expectLater(
    find.byKey(const ValueKey('transition-frames-root')),
    matchesGoldenFile('goldens/player_route_$name.png'),
  );
  expect(tester.takeException(), isNull);
}

void _expectPreviewCover(WidgetTester tester, Rect source) {
  final target = tester.getRect(
    find.byWidgetPredicate(
      (widget) => widget is PlayerArtworkHero && widget.isPlayerPageTarget,
      skipOffstage: false,
    ),
  );
  final expected = Rect.lerp(source, target, _route(tester).debugVisualValue)!;
  final actual = tester.getRect(
    find.byKey(const ValueKey('player-artwork-flight-frame')),
  );
  expect(actual.left, closeTo(expected.left, 0.01));
  expect(actual.top, closeTo(expected.top, 0.01));
  expect(actual.width, closeTo(expected.width, 0.01));
  expect(actual.height, closeTo(expected.height, 0.01));
}

Future<void> pumpPlayer(
  WidgetTester tester, {
  bool withDock = false,
  double bottomInset = 0,
  bool withLyrics = false,
  double railWidth = 0,
  Size size = const Size(390, 844),
  Stream<PlayerState>? playerStates,
  Stream<AudioTrack?>? tracks,
}) async {
  SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = FakeViewPadding(bottom: bottomInset);
  tester.view.viewPadding = FakeViewPadding(bottom: bottomInset);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentTrackProvider.overrideWith(
          (ref) => tracks ?? Stream.value(track),
        ),
        isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
        positionProvider.overrideWith(
          (ref) => Stream.value(const Duration(seconds: 42)),
        ),
        durationProvider.overrideWith(
          (ref) => Stream.value(const Duration(minutes: 4)),
        ),
        playerStateProvider.overrideWith(
          (ref) =>
              playerStates ??
              Stream.value(PlayerState(withLyrics, ProcessingState.ready)),
        ),
        if (withLyrics)
          lyricControllerProvider.overrideWith(
            (ref) => LyricController(
              ref,
              initialState: LyricState(
                lyrics: [
                  LyricLine(
                    startTime: Duration.zero,
                    endTime: const Duration(minutes: 4),
                    text: 'Current lyric',
                  ),
                ],
              ),
            ),
          ),
        queueProvider.overrideWith((ref) => Stream.value([track])),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
      ],
      child: RepaintBoundary(
        key: const ValueKey('transition-frames-root'),
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          theme: ThemeData.dark(useMaterial3: true),
          home: AppBottomDockTransitionScope(
            sourceHasAppTabBar: withDock,
            child: Padding(
              padding: EdgeInsets.only(left: railWidth),
              child: Scaffold(
                body: const Center(child: Text('Player')),
                bottomNavigationBar: withDock
                    ? AppBottomDock(
                        selectedIndex: 0,
                        onDestinationSelected: (_) {},
                        miniPlayer: const MiniPlayer(),
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.home),
                            label: 'Home',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.search),
                            label: 'Search',
                          ),
                        ],
                      )
                    : const SafeArea(top: false, child: MiniPlayer()),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

AudioPlayerPageRoute<void> _route(WidgetTester tester) =>
    ModalRoute.of(tester.element(find.byType(AudioPlayerScreen)))!
        as AudioPlayerPageRoute<void>;

Future<Uint8List> _pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('transition-frames-root')),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return Uint8List.fromList(bytes!.buffer.asUint8List());
  }))!;
}

void _surfaceRegressions() {
  for (final complete in [false, true]) {
    testWidgets(
      'reduced motion completes preview handoff or cleanup $complete',
      (tester) async {
        await pumpPlayer(tester, withDock: true, bottomInset: 34);
        final launcher = find.byKey(
          const ValueKey('mini-player-upward-launcher'),
        );
        final gesture = await tester.startGesture(tester.getCenter(launcher));
        await gesture.moveBy(const Offset(0, -260));
        await tester.pump();
        await tester.pump();
        if (complete) {
          await gesture.up();
        } else {
          await gesture.cancel();
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 35));
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('player-route-bottom-dock')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('player-artwork-flight-frame')),
          findsNothing,
        );
        expect(
          find.byType(AudioPlayerScreen),
          complete ? findsOneWidget : findsNothing,
        );
        if (complete) {
          expect(_route(tester).debugVisualValue, 1);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        }
        expect(find.byType(AudioPlayerScreen), findsNothing);
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(find.byType(MiniPlayer), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final hasCover in [false, true]) {
    testWidgets(
      'mini cover fades only when no cover flight is available $hasCover',
      (tester) async {
        await pumpPlayer(tester, withDock: true);
        await tester.tap(
          find.byKey(const ValueKey('mini-player-upward-launcher')),
        );
        await tester.pumpAndSettle();
        final route = _route(tester);
        route.beginVerticalDismissGesture(
          hasCover
              ? PlayerDismissVisualMode.main
              : PlayerDismissVisualMode.secondary,
        );
        route.updateVerticalDismissGesture(distance: 844 * 0.9, extent: 844);
        await tester.pump();
        final presentationCover = find.descendant(
          of: find.byKey(const ValueKey('player-route-mini-player-opacity')),
          matching: find.byKey(const ValueKey('mini-player-artwork-frame')),
        );
        expect(presentationCover, hasCover ? findsNothing : findsOneWidget);
        route.cancelVerticalDismissGesture();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final withDock in [false, true]) {
    for (final inset in [0.0, 34.0]) {
      for (final lyrics in [false, true]) {
        testWidgets(
          'measured reveal dock=$withDock inset=$inset lyrics=$lyrics',
          (tester) async {
            await pumpPlayer(
              tester,
              withDock: withDock,
              bottomInset: inset,
              withLyrics: lyrics,
            );
            final launcher = find.byKey(
              const ValueKey('mini-player-upward-launcher'),
            );
            final mini = tester.getRect(launcher);
            expect(mini.height, lyrics ? 88 : 72);
            final dock = withDock
                ? tester.getRect(find.byType(NavigationBar))
                : null;
            await tester.tap(launcher);
            await tester.pump();
            await tester.pump();
            final route = _route(tester);
            expect(route.beginVerticalOpenGesture(), isTrue);
            for (final p in [0.01, 0.1, 0.3, 0.6, 0.9]) {
              route.updateVerticalOpenGesture(distance: 844 * p, extent: 844);
              await tester.pump();
              final reveal = playerRouteRevealRect(tester);
              expect(reveal.top, closeTo(mini.top * (1 - p), 0.01));
              expect(reveal.bottom, 844);
              expect(reveal.width, 390);
              if (dock != null) {
                final visibleDock = tester.getRect(
                  find.byKey(const ValueKey('player-route-bottom-dock')),
                );
                expect(
                  visibleDock.top,
                  closeTo(dock.top + dock.height * p, 0.01),
                );
                expect(visibleDock.size, dock.size);
              }
            }
            final completed = route.endVerticalOpenGesture(
              velocity: 0,
              extent: 844,
            );
            await tester.pumpAndSettle();
            expect(await completed, isTrue);
            expect(
              route.beginVerticalDismissGesture(PlayerDismissVisualMode.main),
              isTrue,
            );
            for (final p in [0.9, 0.6, 0.3, 0.1, 0.01, 0.1]) {
              route.updateVerticalDismissGesture(
                distance: 844 * (1 - p),
                extent: 844,
              );
              await tester.pump();
              expect(
                playerRouteRevealRect(tester).top,
                closeTo(mini.top * (1 - p), 0.01),
              );
              expect(playerRouteRevealRect(tester).bottom, 844);
            }
            route.endVerticalDismissGesture(velocity: 800, extent: 844);
            await tester.pumpAndSettle();
            expect(find.byType(AudioPlayerScreen), findsNothing);
            expect(tester.getRect(launcher), mini);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('opening settle can be grabbed again and reversed by pointer', (
    tester,
  ) async {
    await pumpPlayer(tester, withDock: true, bottomInset: 34);
    final launcher = find.byKey(const ValueKey('mini-player-upward-launcher'));
    final start = tester.getCenter(launcher);
    final opening = await tester.startGesture(start);
    await opening.moveBy(const Offset(0, -260));
    await tester.pump();
    await tester.pump();
    await opening.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 35));
    final route = _route(tester);
    final before = route.debugVisualValue;
    final flight = find.byKey(const ValueKey('player-artwork-flight-frame'));
    final artworkBefore = tester.getRect(flight);
    final resumed = await tester.startGesture(const Offset(190, 200));
    await tester.pump();
    expect(route.debugVisualValue, closeTo(before, 0.0001));
    expect(
      tester.getRect(flight),
      rectMoreOrLessEquals(artworkBefore, epsilon: 0.001),
    );
    await resumed.moveBy(const Offset(0, 400));
    await tester.pump();
    expect(route.debugVisualValue, lessThan(before));
    await resumed.cancel();
    await tester.pumpAndSettle();
    expect(find.byType(AudioPlayerScreen), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('automatic opening transfers to drag without a visible jump', (
    tester,
  ) async {
    await pumpPlayer(tester, withDock: true);
    await tester.tap(find.byKey(const ValueKey('mini-player-upward-launcher')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final route = _route(tester);
    final before = playerRouteRevealRect(tester);
    final p = route.debugVisualValue;
    final flight = find.byKey(const ValueKey('player-artwork-flight-frame'));
    final artworkBefore = tester.getRect(flight);
    expect(
      route.beginVerticalDismissGesture(PlayerDismissVisualMode.main),
      isTrue,
    );
    await tester.pump();
    expect(route.debugVisualValue, closeTo(p, 0.0001));
    expect(playerRouteRevealRect(tester), before);
    expect(
      tester.getRect(flight),
      rectMoreOrLessEquals(artworkBefore, epsilon: 0.001),
    );
    route.cancelVerticalDismissGesture();
    await tester.pumpAndSettle();
    expect(route.debugVisualValue, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'exit remeasures the mini player after its lyric height changes',
    (tester) async {
      final states = StreamController<PlayerState>.broadcast();
      addTearDown(states.close);
      await pumpPlayer(
        tester,
        withDock: true,
        withLyrics: true,
        playerStates: states.stream,
      );
      states.add(PlayerState(false, ProcessingState.ready));
      await tester.pumpAndSettle();
      final launcher = find.byKey(
        const ValueKey('mini-player-upward-launcher'),
        skipOffstage: false,
      );
      final initial = tester.getRect(launcher);
      expect(initial.height, 72);
      await tester.tap(launcher);
      await tester.pumpAndSettle();
      states.add(PlayerState(true, ProcessingState.ready));
      await tester.pumpAndSettle();
      final updated = tester.getRect(launcher);
      expect(updated.height, 88);
      final route = _route(tester);
      route.beginVerticalDismissGesture(PlayerDismissVisualMode.main);
      route.updateVerticalDismissGesture(distance: 422, extent: 844);
      await tester.pump();
      expect(playerRouteRevealRect(tester).top, closeTo(updated.top / 2, 0.01));
      route.cancelVerticalDismissGesture();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'dock and safe area keyframes return to the identical source frame',
    (tester) async {
      await pumpPlayer(tester, withDock: true, bottomInset: 34);
      final source = await _pixels(tester);
      await tester.tap(
        find.byKey(const ValueKey('mini-player-upward-launcher')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      await frame(tester, 'dock_open_30');
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 370));
      await frame(tester, 'dock_close_370');
      await tester.pump(const Duration(milliseconds: 79));
      await frame(tester, 'dock_close_449');
      await tester.pumpAndSettle();
      await frame(tester, 'dock_closed');
      expect(await _pixels(tester), source);
    },
  );

  testWidgets('wide player uses full width and the actual inset source top', (
    tester,
  ) async {
    await pumpPlayer(
      tester,
      size: const Size(1280, 720),
      bottomInset: 24,
      railWidth: 80,
    );
    final launcher = find.byKey(const ValueKey('mini-player-upward-launcher'));
    final source = tester.getRect(launcher);
    expect(source.left, 80);
    await tester.tap(launcher);
    await tester.pumpAndSettle();
    final route = _route(tester);
    route.beginVerticalDismissGesture(PlayerDismissVisualMode.main);
    route.updateVerticalDismissGesture(distance: 360, extent: 720);
    await tester.pump();
    expect(
      playerRouteRevealRect(tester),
      Rect.fromLTRB(0, source.top / 2, 1280, 720),
    );
    route.cancelVerticalDismissGesture();
    await tester.pumpAndSettle();
  });
}

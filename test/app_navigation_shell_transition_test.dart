import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/update_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_navigation_scope.dart';
import 'package:kikoeru_flutter/src/widgets/app_navigation_shell.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_lyrics_surface.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = AudioTrack(
  id: 'shell-transition-track',
  title: 'Audio',
  url: 'https://example.invalid/audio.mp3',
);

Future<AppNavigationController> _pumpShell(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  bool reducedMotion = false,
  bool withTrack = true,
  FakeViewPadding safePadding = FakeViewPadding.zero,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = safePadding;
  tester.view.viewPadding = safePadding;
  addTearDown(tester.view.reset);
  final navigation = AppNavigationController();
  addTearDown(navigation.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentTrackProvider.overrideWith(
          (ref) => Stream.value(withTrack ? _track : null),
        ),
        showUpdateRedDotProvider.overrideWith((ref) => false),
        positionProvider.overrideWith(
          (ref) => Stream.value(const Duration(seconds: 30)),
        ),
        durationProvider.overrideWith(
          (ref) => Stream.value(const Duration(minutes: 4)),
        ),
        playerStateProvider.overrideWith(
          (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
        ),
        queueProvider.overrideWith((ref) => Stream.value([_track])),
        manualSkipAvailabilityProvider.overrideWith(
          (ref) => Stream.value(ManualSkipAvailability.unavailable),
        ),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
        audioSliceStateProvider.overrideWith((ref) => const Stream.empty()),
        isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
        lyricControllerProvider.overrideWith(
          (ref) => LyricController(
            ref,
            initialState: LyricState(
              lyrics: List.generate(
                80,
                (i) => LyricLine(
                  startTime: Duration(seconds: i),
                  endTime: Duration(seconds: i + 1),
                  text: 'stable lyric line $i',
                ),
              ),
            ),
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        navigatorObservers: [navigation],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: AppNavigationShell(controller: navigation, child: child!),
        ),
        home: const Scaffold(
          body: SizedBox.expand(key: ValueKey('home-viewport')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return navigation;
}

AudioPlayerPageRoute<void> _openPlayer(
  AppNavigationController navigation, {
  bool lyrics = false,
  bool handoff = false,
}) {
  final route = AudioPlayerPageRoute<void>(
    skipInitialTransition: handoff,
    builder: (_) => Scaffold(
      resizeToAvoidBottomInset: false,
      body: lyrics
          ? PlayerLyricsSurface(
              isWide: false,
              onFullscreen: () {},
              translateButton: const Icon(Icons.translate),
            )
          : const SizedBox.expand(key: ValueKey('player-viewport')),
    ),
  );
  unawaited(navigation.navigator!.push(route));
  return route;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets('Dock and Mini Player slide down together on player entry', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester);
    final dock = find.byType(AppBottomDock);
    final mini = find.byType(MiniPlayer);
    final dockTop = tester.getTopLeft(dock).dy;
    final miniTop = tester.getTopLeft(mini).dy;
    _openPlayer(navigation);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(dock, findsOneWidget);
    final distance = tester.getTopLeft(dock).dy - dockTop;
    expect(distance, greaterThan(0));
    expect(distance, lessThan(844 - dockTop));
    expect(tester.getTopLeft(mini).dy - miniTop, closeTo(distance, 0.01));
    expect(find.byType(NavigationBar).hitTestable(), findsNothing);
    await tester.pumpAndSettle();
    expect(dock, findsNothing);
  });

  testWidgets('Dock slides up only after the player exit completes', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester);
    final dock = find.byType(AppBottomDock);
    final initialTop = tester.getTopLeft(dock).dy;
    final route = _openPlayer(navigation);
    await tester.pumpAndSettle();
    var exitCompleted = false;
    unawaited(route.completed.then((_) => exitCompleted = true));
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(exitCompleted, isFalse);
    expect(dock, findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(exitCompleted, isTrue);
    expect(tester.getTopLeft(dock).dy, closeTo(844, 0.01));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getTopLeft(dock).dy, greaterThan(initialTop));
    expect(tester.getTopLeft(dock).dy, lessThan(844));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(dock).dy, closeTo(initialTop, 0.01));
  });

  testWidgets('landscape playback and navigation slide out of the viewport', (
    tester,
  ) async {
    final navigation = await _pumpShell(
      tester,
      size: const Size(1280, 720),
      safePadding: const FakeViewPadding(left: 44, right: 12, bottom: 20),
    );
    final mini = find.byType(MiniPlayer);
    final rail = find.byType(NavigationRail);
    final initialMiniRect = tester.getRect(mini);
    final initialRailLeft = tester.getTopLeft(rail).dx;
    _openPlayer(navigation);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getTopLeft(mini).dy, greaterThan(initialMiniRect.top));
    expect(tester.getRect(mini).left, initialMiniRect.left);
    expect(tester.getRect(mini).width, initialMiniRect.width);
    expect(tester.getTopLeft(rail).dx, lessThan(initialRailLeft));
    expect(rail.hitTestable(), findsNothing);
    await tester.pumpAndSettle();
    expect(mini, findsNothing);
    expect(rail, findsNothing);
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(mini, findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(tester.getRect(mini).left, initialMiniRect.left);
    expect(tester.getRect(mini).width, initialMiniRect.width);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(mini).dy, closeTo(initialMiniRect.top, 0.01));
    expect(tester.getTopLeft(rail).dx, initialRailLeft);
  });

  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    testWidgets(
      'interactive preview retains navigation until handoff at $size',
      (tester) async {
        final navigation = await _pumpShell(
          tester,
          size: size,
          safePadding: size.width > size.height
              ? const FakeViewPadding(left: 44, right: 12, bottom: 20)
              : FakeViewPadding.zero,
        );
        final mini = find.byType(MiniPlayer, skipOffstage: false);
        final miniState = tester.state(mini);
        final miniTop = tester.getTopLeft(mini).dy;
        final dock = find.byType(AppBottomDock, skipOffstage: false);
        final rail = find.byType(NavigationRail, skipOffstage: false);

        navigation.setPlayerLaunchPreview(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));

        expect(navigation.navigationVisible, isFalse);
        expect(mini, findsOneWidget);
        expect(tester.state(mini), same(miniState));
        if (size.width > size.height) {
          expect(rail, findsOneWidget);
          expect(tester.getRect(rail).right, lessThanOrEqualTo(0));
          expect(tester.getTopLeft(mini).dy, greaterThan(miniTop));
          expect(rail.hitTestable(), findsNothing);
          expect(mini.hitTestable(), findsNothing);
        } else {
          expect(dock, findsOneWidget);
          expect(tester.getTopLeft(dock).dy, closeTo(size.height, 0.01));
          expect(dock.hitTestable(), findsNothing);
          expect(mini.hitTestable(), findsNothing);
        }

        _openPlayer(navigation, handoff: true);
        navigation.setPlayerLaunchPreview(false);
        await tester.pump();

        expect(find.byKey(const ValueKey('player-viewport')), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const ValueKey('player-viewport'))),
          size,
        );
        expect(dock, findsNothing);
        expect(rail, findsNothing);
        expect(mini, findsNothing);

        navigation.navigator!.pop();
        await tester.pumpAndSettle();
        expect(mini, findsOneWidget);
        expect(
          size.width > size.height ? rail.hitTestable() : dock.hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('landscape reader preview preserves its immersive viewport', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester, size: const Size(1280, 720));
    unawaited(
      navigation.navigator!.push<void>(
        MaterialPageRoute<void>(
          settings: appImmersiveRouteSettings,
          builder: (_) => const Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: SizedBox.expand(
                    key: ValueKey('immersive-reader-viewport'),
                  ),
                ),
                MiniPlayer(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final viewport = find.byKey(const ValueKey('immersive-reader-viewport'));
    final initialRect = tester.getRect(viewport);
    final mini = find.byType(MiniPlayer, skipOffstage: false);
    final miniState = tester.state(mini);
    final launcher = find.byKey(const ValueKey('mini-player-upward-launcher'));
    final gesture = await tester.startGesture(tester.getCenter(launcher));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));

    expect(tester.getRect(viewport), initialRect);
    expect(find.byType(NavigationRail, skipOffstage: false), findsNothing);
    expect(mini, findsOneWidget);
    expect(tester.state(mini), same(miniState));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(navigation.navigationVisible, isFalse);
    expect(tester.getRect(viewport), initialRect);
    expect(mini, findsOneWidget);
    expect(tester.state(mini), same(miniState));
    expect(launcher.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('video fullscreen history preserves preview Dock slides', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester);
    final videoTransition = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(videoTransition.dispose);
    final home = ModalRoute.of(
      tester.element(find.byKey(const ValueKey('home-viewport'))),
    )!;
    navigation.setFullscreen(home, false, transition: videoTransition);
    await tester.pumpAndSettle();
    final dock = find.byType(AppBottomDock);
    final dockTop = tester.getTopLeft(dock).dy;
    navigation.setPlayerLaunchPreview(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(dock, findsOneWidget);
    expect(tester.getTopLeft(dock).dy, greaterThan(dockTop));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(dock).dy, closeTo(844, 0.01));
    navigation.setPlayerLaunchPreview(false);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(dock).dy, closeTo(dockTop, 0.01));
  });

  testWidgets('video fullscreen history preserves audio Dock slides', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester);
    final videoTransition = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(videoTransition.dispose);
    final home = ModalRoute.of(
      tester.element(find.byKey(const ValueKey('home-viewport'))),
    )!;
    navigation.setFullscreen(home, false, transition: videoTransition);
    await tester.pumpAndSettle();
    final dock = find.byType(AppBottomDock);
    final dockTop = tester.getTopLeft(dock).dy;
    _openPlayer(navigation);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(dock, findsOneWidget);
    expect(tester.getTopLeft(dock).dy, greaterThan(dockTop));
    await tester.pumpAndSettle();
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(tester.getTopLeft(dock).dy, closeTo(844, 0.01));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getTopLeft(dock).dy, greaterThan(dockTop));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(dock).dy, closeTo(dockTop, 0.01));
  });

  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    testWidgets('player retains full viewport on entry at $size', (
      tester,
    ) async {
      final navigation = await _pumpShell(tester, size: size);
      _openPlayer(navigation);
      await tester.pump();
      for (final elapsed in [20, 60, 100, 220]) {
        await tester.pump(Duration(milliseconds: elapsed));
        expect(
          tester.getSize(find.byKey(const ValueKey('player-viewport'))),
          size,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('keyboard clips lyrics without shrinking the player surface', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester, withTrack: false);
    _openPlayer(navigation, lyrics: true);
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('player-lyrics-surface-false'));
    final viewport = find.byKey(const ValueKey('lyric-keyboard-safe-viewport'));
    final initialSurface = tester.getRect(surface);
    final initialViewport = tester.getRect(viewport);
    final line = find.text('stable lyric line 30');
    final initialLine = tester.getRect(line);
    await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
    await tester.pumpAndSettle();
    for (final inset in [100.0, 220.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pumpAndSettle();
      expect(tester.getRect(surface), initialSurface);
      expect(tester.getRect(line), initialLine);
      expect(tester.getRect(viewport).top, initialViewport.top);
      expect(tester.getRect(viewport).height, lessThan(initialViewport.height));
    }
    await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(tester.getRect(surface), initialSurface);
    expect(tester.getRect(viewport), initialViewport);
  });

  testWidgets('reduced motion restores the Dock without a slide', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester, reducedMotion: true);
    final initialRect = tester.getRect(find.byType(AppBottomDock));
    _openPlayer(navigation);
    await tester.pumpAndSettle();
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(tester.getRect(find.byType(AppBottomDock)), initialRect);
    expect(tester.takeException(), isNull);
  });
}

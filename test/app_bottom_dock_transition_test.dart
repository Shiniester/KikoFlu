import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';
import 'package:kikoeru_flutter/src/widgets/global_audio_player_wrapper.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_cover_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _configurePhoneViewport(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
}) {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

List<Override> _playerOverrides(AudioTrack track) => [
  currentTrackProvider.overrideWith((ref) => Stream.value(track)),
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
];

void main() {
  testWidgets('main bottom dock moves together into work details', (
    tester,
  ) async {
    _configurePhoneViewport(tester);

    final navigatorKey = GlobalKey<NavigatorState>();
    const sourceMiniKey = ValueKey('source-mini-player');
    const targetMiniKey = ValueKey('target-mini-player');
    const tabBarKey = ValueKey('source-app-tab-bar');

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: AppBottomDockTransitionScope(
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () {
                    unawaited(
                      pushWorkDetailRoute(
                        context,
                        builder: (_) => const _WorkDetailsTarget(
                          miniPlayerKey: targetMiniKey,
                        ),
                      ),
                    );
                  },
                  child: const Text('Open work details'),
                ),
              ),
            ),
            bottomNavigationBar: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppBottomDockMiniPlayerHero.source(
                  child: SizedBox(
                    key: sourceMiniKey,
                    width: double.infinity,
                    height: 72,
                  ),
                ),
                AppBottomDockTabBarHero.source(
                  child: SizedBox(
                    key: tabBarKey,
                    width: double.infinity,
                    height: 58,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.getTopLeft(find.byKey(sourceMiniKey)).dy, 714);
    expect(tester.getTopLeft(find.byKey(tabBarKey)).dy, 786);

    await tester.tap(find.text('Open work details'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 225));

    expect(tester.getTopLeft(find.byKey(targetMiniKey)).dy, closeTo(743, 0.1));
    expect(tester.getTopLeft(find.byKey(tabBarKey)).dy, closeTo(815, 0.1));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(targetMiniKey)).dy, 772);
    expect(find.byKey(tabBarKey), findsNothing);

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 225));

    expect(tester.getTopLeft(find.byKey(targetMiniKey)).dy, closeTo(743, 0.1));
    expect(tester.getTopLeft(find.byKey(tabBarKey)).dy, closeTo(815, 0.1));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(sourceMiniKey)).dy, 714);
    expect(tester.getTopLeft(find.byKey(tabBarKey)).dy, 786);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('main screen exposes the Bottom Dock as the source', (
    tester,
  ) async {
    _configurePhoneViewport(tester);

    const sourceMiniKey = ValueKey('real-source-mini-player');
    const targetMiniKey = ValueKey('real-target-mini-player');
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: AppBottomDockTransitionScope(
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () {
                    unawaited(
                      pushWorkDetailRoute(
                        context,
                        builder: (_) => const _WorkDetailsTarget(
                          miniPlayerKey: targetMiniKey,
                        ),
                      ),
                    );
                  },
                  child: const Text('Open from main navigation'),
                ),
              ),
            ),
            bottomNavigationBar: AppBottomDock(
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
                NavigationDestination(
                  icon: Icon(Icons.search),
                  label: 'Search',
                ),
              ],
              miniPlayer: const SizedBox(
                key: sourceMiniKey,
                width: double.infinity,
                height: 72,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open from main navigation'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 225));

    expect(tester.getTopLeft(find.byKey(targetMiniKey)).dy, closeTo(743, 0.1));
    expect(tester.getTopLeft(find.byType(NavigationBar)).dy, closeTo(815, 0.1));

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('bottom-only mini player stays fixed into work details', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    _configurePhoneViewport(tester);
    final navigatorKey = GlobalKey<NavigatorState>();
    const track = AudioTrack(
      id: 'dock-track',
      title: 'Dock track',
      url: 'https://example.invalid/audio.mp3',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: _playerOverrides(track),
        child: MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: GlobalAudioPlayerWrapper(
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () {
                      unawaited(
                        pushWorkDetailRoute(
                          context,
                          builder: (_) =>
                              const GlobalAudioPlayerWrapper.workDetails(
                                child: Scaffold(body: Text('Work details')),
                              ),
                        ),
                      );
                    },
                    child: const Text('Open from bottom-only page'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final miniPlayer = find.byKey(const ValueKey('mini-player-dismissible'));
    expect(tester.getTopLeft(miniPlayer).dy, 772);

    await tester.tap(find.text('Open from bottom-only page'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 225));

    expect(tester.getTopLeft(miniPlayer).dy, 772);
    expect(
      find.byKey(const ValueKey('player-artwork-flight-frame')),
      findsNothing,
    );

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(miniPlayer).dy, 772);
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('without playback only the App Tab Bar joins the handoff', (
    tester,
  ) async {
    _configurePhoneViewport(tester);

    await tester.pumpWidget(
      MaterialApp(
        home: AppBottomDockTransitionScope(
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () {
                    unawaited(
                      pushWorkDetailRoute(
                        context,
                        builder: (_) =>
                            const _WorkDetailsTarget(miniPlayerKey: null),
                      ),
                    );
                  },
                  child: const Text('Open without playback'),
                ),
              ),
            ),
            bottomNavigationBar: AppBottomDock(
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
                NavigationDestination(
                  icon: Icon(Icons.search),
                  label: 'Search',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.byType(AppBottomDockMiniPlayerHero), findsNothing);
    await tester.tap(find.text('Open without playback'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 225));

    expect(find.byType(AppBottomDockMiniPlayerHero), findsNothing);
    expect(tester.getTopLeft(find.byType(NavigationBar)).dy, closeTo(815, 0.1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS back swipe reverses continuously and can cancel', (
    tester,
  ) async {
    _configurePhoneViewport(tester, platform: TargetPlatform.iOS);
    const sourceMiniKey = ValueKey('interactive-source-mini');
    const targetMiniKey = ValueKey('interactive-target-mini');

    await tester.pumpWidget(
      MaterialApp(
        home: AppBottomDockTransitionScope(
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () {
                    unawaited(
                      pushWorkDetailRoute(
                        context,
                        builder: (_) => const _WorkDetailsTarget(
                          miniPlayerKey: targetMiniKey,
                        ),
                      ),
                    );
                  },
                  child: const Text('Open interactive details'),
                ),
              ),
            ),
            bottomNavigationBar: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppBottomDockMiniPlayerHero.source(
                  child: SizedBox(
                    key: sourceMiniKey,
                    width: double.infinity,
                    height: 72,
                  ),
                ),
                AppBottomDockTabBarHero.source(
                  child: SizedBox(width: double.infinity, height: 58),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open interactive details'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(targetMiniKey)).dy, 772);

    final cancelledSwipe = await tester.startGesture(const Offset(1, 400));
    await cancelledSwipe.moveBy(const Offset(110, 0));
    await tester.pump();
    final cancelledMidpoint = tester.getTopLeft(find.byKey(targetMiniKey)).dy;
    expect(cancelledMidpoint, greaterThan(714));
    expect(cancelledMidpoint, lessThan(772));
    await cancelledSwipe.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(targetMiniKey)).dy, 772);

    await tester.dragFrom(const Offset(1, 400), const Offset(330, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(sourceMiniKey)).dy, 714);
    expect(find.byKey(targetMiniKey), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('landed work details mini player opens with artwork hero', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
    _configurePhoneViewport(tester);
    const track = AudioTrack(
      id: 'work-details-player-track',
      title: 'Work details player track',
      url: 'https://example.invalid/audio.mp3',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: _playerOverrides(track),
        child: const MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: GlobalAudioPlayerWrapper.workDetails(
            child: Scaffold(body: Text('Landed work details')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('mini-player-artwork-frame')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Hero &&
            widget.tag ==
                playerArtworkHeroTag(track.id, PlayerArtworkFlightTarget.main),
      ),
      findsWidgets,
    );
    expect(
      find.byKey(const ValueKey('player-artwork-flight-frame')),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Hero && widget.tag == 'app-bottom-dock-mini-player',
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('player-artwork-flight-frame')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Hero && widget.tag == 'app-bottom-dock-mini-player',
      ),
      findsOneWidget,
    );
    expect(find.text('Landed work details'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

class _WorkDetailsTarget extends StatelessWidget {
  const _WorkDetailsTarget({required this.miniPlayerKey});

  final Key? miniPlayerKey;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.white),
          if (miniPlayerKey case final miniPlayerKey?)
            Align(
              alignment: Alignment.bottomCenter,
              child: AppBottomDockMiniPlayerHero.target(
                child: SizedBox(
                  key: miniPlayerKey,
                  width: double.infinity,
                  height: 72,
                ),
              ),
            ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: AppBottomDockTabBarHero.offstageTarget(height: 58),
          ),
        ],
      ),
    );
  }
}

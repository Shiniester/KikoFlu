import 'package:dio/dio.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/subtitle_library_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/screens/search_result_screen.dart';
import 'package:kikoeru_flutter/src/widgets/enhanced_work_card.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/utils/theme.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';
import 'package:kikoeru_flutter/src/widgets/global_audio_player_wrapper.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_cover_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';

void _configurePhoneViewport(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  double bottomInset = 0,
  double devicePixelRatio = 1,
}) {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = Size(
    390 * devicePixelRatio,
    844 * devicePixelRatio,
  );
  tester.view.padding = FakeViewPadding(bottom: bottomInset * devicePixelRatio);
  tester.view.viewPadding = FakeViewPadding(
    bottom: bottomInset * devicePixelRatio,
  );
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
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
  manualSkipAvailabilityProvider.overrideWith(
    (ref) => Stream.value(ManualSkipAvailability.unavailable),
  ),
  lyricAutoLoaderProvider.overrideWith((ref) {}),
];

Rect _flightChildRect(
  WidgetTester tester, {
  required ValueKey<String> flightRootKey,
  required Key childKey,
}) {
  return tester.getRect(
    find.descendant(
      of: find.byKey(flightRootKey),
      matching: find.byKey(childKey),
    ),
  );
}

double _dockFlightGap(WidgetTester tester) {
  final mini = tester.getRect(
    find.byKey(appBottomDockMiniPlayerHandoffRootKey),
  );
  final icon = _flightChildRect(
    tester,
    flightRootKey: appBottomDockTabBarHandoffRootKey,
    childKey: const ValueKey('real-gap-navigation-icon'),
  );
  return icon.top - mini.bottom;
}

Rect _dockFlightRect(WidgetTester tester) {
  return tester.getRect(find.byKey(appBottomDockMiniPlayerHandoffRootKey));
}

SnapshotController _snapshotControllerFor(WidgetTester tester, Key key) {
  final snapshot = find.ancestor(
    of: find.byKey(key, skipOffstage: false),
    matching: find.byType(SnapshotWidget, skipOffstage: false),
  );
  return tester.widget<SnapshotWidget>(snapshot.first).controller;
}

double _settledDockGap(WidgetTester tester) {
  final mini = tester.getRect(
    find.byKey(const ValueKey('real-gap-source-mini')),
  );
  final icon = tester.getRect(
    find.byKey(const ValueKey('real-gap-navigation-icon')),
  );
  return icon.top - mini.bottom;
}

class _TagApi extends KikoeruApiService {
  @override
  Future<Map<String, dynamic>> getWorksByTag({
    required int tagId,
    int page = 1,
    int pageSize = 40,
    String? order,
    String? sort,
    int? subtitle,
    int? seed,
    CancelToken? cancelToken,
  }) async => {'works': []};
}

class _TagAuth extends AuthNotifier {
  _TagAuth() : super(_TagApi()) {
    state = const AuthState();
  }
}

class _NoSubtitles extends SubtitleLibraryNotifier {
  @override
  Future<void> refresh() async {}
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  for (final inset in [0.0, 34.0]) {
    testWidgets('Dock follows route easing and live height with inset $inset', (
      tester,
    ) async {
      _configurePhoneViewport(
        tester,
        bottomInset: inset,
        devicePixelRatio: inset == 0 ? 1 : 3,
      );
      final height = ValueNotifier<double>(72);
      addTearDown(height.dispose);
      final navigator = GlobalKey<NavigatorState>();
      const sourceKey = ValueKey('easing-source');
      const targetKey = ValueKey('easing-target');
      const iconKey = ValueKey('easing-icon');
      late BuildContext sourceContext;
      Widget mini(Key key) => ValueListenableBuilder<double>(
        valueListenable: height,
        builder: (_, value, __) =>
            SizedBox(key: key, width: double.infinity, height: value),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme(null),
          navigatorKey: navigator,
          home: AppBottomDockTransitionScope(
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  sourceContext = context;
                  return const SizedBox.expand();
                },
              ),
              bottomNavigationBar: AppBottomDock(
                selectedIndex: 0,
                onDestinationSelected: (_) {},
                miniPlayer: mini(sourceKey),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.home, key: iconKey),
                    label: 'Home',
                  ),
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
      final sourceRect = tester.getRect(find.byKey(sourceKey));
      final gap = tester.getRect(find.byKey(iconKey)).top - sourceRect.bottom;
      unawaited(
        pushBottomDockRoute(
          sourceContext,
          builder: (_) => Scaffold(
            body: Column(
              children: [
                const Expanded(child: SizedBox()),
                AppBottomDockMiniPlayer.target(child: mini(targetKey)),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      var layerBuilds = 0;
      debugOnRebuildDirtyWidget = (element, built) {
        if (element.widget.runtimeType.toString() == '_DockTransitionLayer') {
          layerBuilds++;
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      final targetState = tester.state(
        find.ancestor(
          of: find.byKey(targetKey),
          matching: find.byType(ValueListenableBuilder<double>),
        ),
      );
      final route =
          ModalRoute.of(tester.element(find.byKey(targetKey)))!
              as PageRoute<void>;
      var elapsed = 0;
      for (final sample in [60, 150, 240]) {
        await tester.pump(Duration(milliseconds: sample - elapsed));
        elapsed = sample;
        final progress = sample / route.transitionDuration.inMilliseconds;
        final rect = tester.getRect(find.byKey(targetKey));
        expect(rect.left, sourceRect.left);
        expect(rect.width, sourceRect.width);
        expect(
          rect.bottom,
          closeTo(
            sourceRect.bottom + (58 + inset) * Curves.ease.transform(progress),
            .01,
          ),
        );
        expect(
          tester.getRect(find.byKey(iconKey)).top - rect.bottom,
          closeTo(gap, .01),
        );
        if (sample <= 150) expect(layerBuilds, 0);
        if (sample == 150) {
          height.value = 88;
          await tester.pump();
          expect(tester.getSize(find.byKey(targetKey)).height, 88);
          expect(
            tester.getRect(find.byKey(iconKey)).top -
                tester.getRect(find.byKey(targetKey)).bottom,
            closeTo(gap, .01),
          );
        }
      }
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(targetKey)).bottom, 844);
      expect(
        tester.state(
          find.ancestor(
            of: find.byKey(targetKey),
            matching: find.byType(ValueListenableBuilder<double>),
          ),
        ),
        same(targetState),
      );
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(sourceKey)).height, 88);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('moving Dock refreshes payload, theme and removed endpoints', (
    tester,
  ) async {
    _configurePhoneViewport(tester, bottomInset: 34);
    final content = ValueNotifier<int>(0);
    addTearDown(content.dispose);
    late BuildContext sourceContext;
    const targetKey = ValueKey('dynamic-target');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(null),
        home: AppBottomDockTransitionScope(
          child: Scaffold(
            body: Builder(
              builder: (context) {
                sourceContext = context;
                return const SizedBox.expand();
              },
            ),
            bottomNavigationBar: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppBottomDockMiniPlayer.source(child: SizedBox(height: 72)),
                AppBottomDockTabBar.source(child: SizedBox(height: 92)),
              ],
            ),
          ),
        ),
      ),
    );
    unawaited(
      pushBottomDockRoute(
        sourceContext,
        builder: (_) => Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: content,
            builder: (context, value, _) => Theme(
              data: Theme.of(context).copyWith(
                colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: value == 0 ? Colors.blue : Colors.purple,
                ),
              ),
              child: Column(
                children: [
                  const Expanded(child: SizedBox()),
                  if (value < 2)
                    AppBottomDockMiniPlayer.target(
                      child: Builder(
                        builder: (context) => SizedBox(
                          key: targetKey,
                          height: value == 0 ? 72 : 88,
                          child: Text(
                            'Mini',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<Text>(find.text('Mini')).style!.color, Colors.blue);
    content.value = 1;
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(tester.getSize(find.byKey(targetKey)).height, 88);
    expect(
      tester
          .getSize(
            find.byWidgetPredicate(
              (widget) =>
                  widget is AppBottomDockMiniPlayer && widget.child is Builder,
            ),
          )
          .height,
      88,
    );
    expect(tester.widget<Text>(find.text('Mini')).style!.color, Colors.purple);
    content.value = 2;
    await tester.pump();
    await tester.pump();
    expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsNothing);
    expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    Navigator.of(sourceContext).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('reduced motion keeps the Dock static through push and return', (
    tester,
  ) async {
    _configurePhoneViewport(tester, bottomInset: 34);
    final navigator = GlobalKey<NavigatorState>();
    late BuildContext sourceContext;
    const sourceKey = ValueKey('reduced-source-mini');
    const targetKey = ValueKey('reduced-target-mini');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(null),
        navigatorKey: navigator,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: AppBottomDockTransitionScope(
          child: Scaffold(
            body: Builder(
              builder: (context) {
                sourceContext = context;
                return const SizedBox.expand();
              },
            ),
            bottomNavigationBar: AppBottomDock(
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              miniPlayer: const SizedBox(key: sourceKey, height: 72),
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
    final sourceRect = tester.getRect(find.byKey(sourceKey));
    unawaited(
      pushBottomDockRoute(
        sourceContext,
        builder: (_) => const Scaffold(
          body: Column(
            children: [
              Expanded(child: SizedBox()),
              AppBottomDockMiniPlayer.target(
                child: SizedBox(key: targetKey, height: 72),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(targetKey)).bottom, 844);
    expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsNothing);
    expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsNothing);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(sourceKey)), sourceRect);
    expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('portrait handoff switches to static landscape before return', (
    tester,
  ) async {
    _configurePhoneViewport(tester);
    final navigator = GlobalKey<NavigatorState>();
    late BuildContext sourceContext;
    const tabKey = ValueKey('rotating-source-tab');
    const targetKey = ValueKey('rotating-target-mini');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(null),
        navigatorKey: navigator,
        home: Builder(
          builder: (context) {
            final landscape =
                MediaQuery.orientationOf(context) == Orientation.landscape;
            return AppBottomDockTransitionScope(
              child: Scaffold(
                body: Builder(
                  builder: (context) {
                    sourceContext = context;
                    return const SizedBox.expand();
                  },
                ),
                bottomNavigationBar: landscape
                    ? null
                    : const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppBottomDockMiniPlayer.source(
                            child: SizedBox(height: 72),
                          ),
                          AppBottomDockTabBar.source(
                            child: SizedBox(key: tabKey, height: 58),
                          ),
                        ],
                      ),
              ),
            );
          },
        ),
      ),
    );
    unawaited(
      pushBottomDockRoute(
        sourceContext,
        builder: (_) => const _WorkDetailsTarget(miniPlayerKey: targetKey),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsOneWidget);
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsNothing);
    expect(find.byKey(tabKey, skipOffstage: false), findsNothing);
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsNothing);
    expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsNothing);
    expect(find.byKey(tabKey, skipOffstage: false), findsNothing);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('nested Mini-only routes retain their own source scope', (
    tester,
  ) async {
    _configurePhoneViewport(tester);
    const track = AudioTrack(
      id: 'nested-track',
      title: 'Audio',
      url: 'https://example.invalid/audio.mp3',
    );
    final navigator = GlobalKey<NavigatorState>();
    late BuildContext sourceContext;
    late BuildContext middleContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: _playerOverrides(track),
        child: MaterialApp(
          theme: AppTheme.lightTheme(null),
          navigatorKey: navigator,
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: GlobalAudioPlayerWrapper(
            child: Builder(
              builder: (context) {
                sourceContext = context;
                return const Scaffold(body: Text('Source'));
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final sourceRect = tester.getRect(find.byType(MiniPlayer));
    unawaited(
      pushBottomDockRoute(
        sourceContext,
        builder: (_) => GlobalAudioPlayerWrapper.workDetails(
          child: Builder(
            builder: (context) {
              middleContext = context;
              return const Scaffold(body: Text('Middle'));
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      pushBottomDockRoute(
        middleContext,
        builder: (_) => const GlobalAudioPlayerWrapper.workDetails(
          child: Scaffold(body: Text('Nested')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_dockFlightRect(tester), sourceRect);
    expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsNothing);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_dockFlightRect(tester), sourceRect);
    await tester.pumpAndSettle();
    expect(find.text('Middle'), findsOneWidget);
    expect(tester.getRect(find.byType(MiniPlayer)), sourceRect);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(MiniPlayer)), sourceRect);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
  for (final isList in [false, true]) {
    testWidgets('audio tag keeps Dock vertical in list layout $isList', (
      tester,
    ) async {
      _configurePhoneViewport(tester);
      const track = AudioTrack(
        id: 'tag-track',
        title: 'Audio',
        url: 'https://example.invalid/audio.mp3',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._playerOverrides(track),
            authProvider.overrideWith((ref) => _TagAuth()),
            kikoeruApiServiceProvider.overrideWithValue(_TagApi()),
            subtitleLibraryProvider.overrideWith((ref) => _NoSubtitles()),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme(null),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: AppBottomDockTransitionScope(
              child: Scaffold(
                body: SingleChildScrollView(
                  child: EnhancedWorkCard(
                    work: const Work(
                      id: 1,
                      title: 'Tagged work',
                      tags: [Tag(id: 999999, name: 'Navigation tag')],
                    ),
                    crossAxisCount: 1,
                    isListLayout: isList,
                  ),
                ),
                bottomNavigationBar: AppBottomDock(
                  selectedIndex: 0,
                  onDestinationSelected: (_) {},
                  miniPlayer: const MiniPlayer(),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.library_music),
                      label: 'Audio',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.menu_book),
                      label: 'Comics',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.settings),
                      label: 'Settings',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final sourceRect = tester.getRect(find.byType(MiniPlayer));
      await tester.ensureVisible(find.text('Navigation tag'));
      await tester.tap(find.text('Navigation tag'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final flight = _dockFlightRect(tester);
      expect(flight.left, sourceRect.left);
      expect(flight.width, sourceRect.width);
      expect(flight.bottom, greaterThan(sourceRect.bottom));
      expect(flight.bottom, lessThan(844));
      expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-artwork-flight-frame')),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(find.byType(SearchResultScreen), findsOneWidget);
      final navigator = Navigator.of(
        tester.element(find.byType(SearchResultScreen)),
      );
      await tester.tap(find.byKey(const ValueKey('mini-player-artwork-frame')));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        find.byKey(const ValueKey('player-artwork-flight-frame')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(SearchResultScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(_dockFlightRect(tester), flight);
      expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-artwork-flight-frame')),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(MiniPlayer)), sourceRect);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final (returnElapsed, landscape) in [
    (60, false),
    (120, false),
    (240, false),
    (120, true),
  ]) {
    testWidgets(
      'work reentry waits for return at ${returnElapsed}ms (landscape: $landscape)',
      (tester) async {
        _configurePhoneViewport(tester);
        if (landscape) tester.view.physicalSize = const Size(844, 390);
        final width = landscape ? 844.0 : 390.0;
        final navigator = GlobalKey<NavigatorState>();
        const homeKey = ValueKey('reentry-home');
        const firstKey = ValueKey('reentry-first');
        const secondKey = ValueKey('reentry-second');
        late BuildContext sourceContext;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.lightTheme(null),
            navigatorKey: navigator,
            home: AppBottomDockTransitionScope(
              child: Scaffold(
                key: homeKey,
                body: Builder(
                  builder: (context) {
                    sourceContext = context;
                    return const SizedBox.expand();
                  },
                ),
              ),
            ),
          ),
        );
        unawaited(
          pushWorkDetailRoute(
            sourceContext,
            builder: (_) => const Scaffold(key: firstKey),
          ),
        );
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(Duration(milliseconds: returnElapsed));
        // Two rapid taps must start only one new route after the return.
        for (var tap = 0; tap < 2; tap++) {
          unawaited(
            pushWorkDetailRoute(
              sourceContext,
              builder: (_) => const Scaffold(key: secondKey),
            ),
          );
        }
        await tester.pump();
        await tester.pump();
        expect(find.byKey(secondKey, skipOffstage: false), findsNothing);
        await tester.pump(Duration(milliseconds: 301 - returnElapsed));
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(find.byKey(firstKey, skipOffstage: false), findsNothing);
        expect(find.byKey(secondKey, skipOffstage: false), findsOneWidget);
        final route =
            ModalRoute.of(tester.element(find.byKey(secondKey)))!
                as PageRoute<void>;
        var elapsed = 0;
        for (final sample in [100, 150, 250]) {
          await tester.pump(Duration(milliseconds: sample - elapsed));
          elapsed = sample;
          final progress = sample / route.transitionDuration.inMilliseconds;
          expect(
            tester.getTopLeft(find.byKey(homeKey, skipOffstage: false)).dx,
            closeTo(-width / 3 * Curves.ease.transform(progress), 0.1),
          );
          expect(
            tester.getTopLeft(find.byKey(secondKey)).dx,
            closeTo(width * (1 - Curves.ease.transform(progress)), 0.1),
          );
        }
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byKey(homeKey), findsOneWidget);
        expect(find.byKey(secondKey, skipOffstage: false), findsNothing);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('main bottom dock moves together into work details', (
    tester,
  ) async {
    _configurePhoneViewport(tester, devicePixelRatio: 3);

    final navigatorKey = GlobalKey<NavigatorState>();
    const sourceMiniKey = ValueKey('source-mini-player');
    const targetMiniKey = ValueKey('target-mini-player');
    const tabBarKey = ValueKey('source-app-tab-bar');
    const homeScaffoldKey = ValueKey('dock-home-route');
    const detailScaffoldKey = ValueKey('dock-detail-route');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(null),
        navigatorKey: navigatorKey,
        home: AppBottomDockTransitionScope(
          child: Scaffold(
            key: homeScaffoldKey,
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () {
                    unawaited(
                      pushWorkDetailRoute(
                        context,
                        builder: (_) => const _WorkDetailsTarget(
                          miniPlayerKey: targetMiniKey,
                          scaffoldKey: detailScaffoldKey,
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
                AppBottomDockMiniPlayer.source(
                  child: SizedBox(
                    key: sourceMiniKey,
                    width: double.infinity,
                    height: 72,
                  ),
                ),
                AppBottomDockTabBar.source(
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

    var rasters = 0;
    final onCreate = ui.Image.onCreate;
    ui.Image.onCreate = (image) {
      onCreate?.call(image);
      if (image.width == 1170 && image.height == 2532) rasters++;
    };
    addTearDown(() => ui.Image.onCreate = onCreate);

    await tester.tap(find.text('Open work details'));
    await tester.pump();
    final homeSnapshot = _snapshotControllerFor(tester, homeScaffoldKey);
    expect(homeSnapshot.allowSnapshotting, isFalse);
    await tester.pump();
    final detailSnapshot = _snapshotControllerFor(tester, detailScaffoldKey);
    expect(detailSnapshot.allowSnapshotting, isFalse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(homeSnapshot.allowSnapshotting, isFalse);
    expect(detailSnapshot.allowSnapshotting, isTrue);
    await tester.pump(const Duration(milliseconds: 134));

    expect(
      tester.getTopLeft(find.byKey(targetMiniKey)).dy,
      closeTo(714 + 58 * Curves.ease.transform(0.5), 0.1),
    );
    expect(tester.getTopLeft(find.byKey(targetMiniKey)).dx, 0);
    expect(
      tester.getTopLeft(find.byKey(tabBarKey)).dy,
      closeTo(786 + 58 * Curves.ease.transform(0.5), 0.1),
    );

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(targetMiniKey)).dy, 772);
    expect(homeSnapshot.allowSnapshotting, isFalse);
    expect(detailSnapshot.allowSnapshotting, isFalse);
    expect(find.byKey(tabBarKey), findsNothing);
    expect(rasters, 1, reason: 'Dock handoff must not rasterize the source.');
    final beforePop = rasters;

    navigatorKey.currentState!.pop();
    await tester.pump();
    expect(homeSnapshot.allowSnapshotting, isFalse);
    expect(detailSnapshot.allowSnapshotting, isFalse);
    await tester.pump(const Duration(milliseconds: 16));
    expect(homeSnapshot.allowSnapshotting, isFalse);
    expect(detailSnapshot.allowSnapshotting, isTrue);
    await tester.pump(const Duration(milliseconds: 134));

    expect(
      tester.getTopLeft(find.byKey(targetMiniKey)).dy,
      closeTo(714 + 58 * Curves.ease.transform(0.5), 0.1),
    );
    expect(tester.getTopLeft(find.byKey(targetMiniKey)).dx, 0);
    expect(
      tester.getTopLeft(find.byKey(tabBarKey)).dy,
      closeTo(786 + 58 * Curves.ease.transform(0.5), 0.1),
    );

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(sourceMiniKey)).dy, 714);
    expect(tester.getTopLeft(find.byKey(tabBarKey)).dy, 786);
    expect(homeSnapshot.allowSnapshotting, isFalse);
    expect(rasters - beforePop, 1);
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
        theme: AppTheme.lightTheme(null),
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
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      tester.getTopLeft(find.byKey(targetMiniKey)).dy,
      closeTo(714 + 58 * Curves.ease.transform(0.5), 0.1),
    );
    expect(tester.getTopLeft(find.byKey(targetMiniKey)).dx, 0);
    expect(
      tester.getTopLeft(find.byType(NavigationBar)).dy,
      closeTo(786 + 58 * Curves.ease.transform(0.5), 0.1),
    );

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('real NavigationBar icon gap stays fixed during dock flight', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    _configurePhoneViewport(tester, bottomInset: 34, devicePixelRatio: 3);
    const sourceMiniKey = ValueKey('real-gap-source-mini');
    const navIconKey = ValueKey('real-gap-navigation-icon');
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: _playerOverrides(
          const AudioTrack(
            id: 'bottom-dock-real-track',
            title: 'Bottom Dock real track',
            url: 'https://example.invalid/audio.mp3',
          ),
        ),
        child: MaterialApp(
          theme: AppTheme.lightTheme(null),
          navigatorKey: navigatorKey,
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
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
                              const GlobalAudioPlayerWrapper.workDetails(
                                child: Scaffold(
                                  body: Text('Real work details'),
                                ),
                              ),
                        ),
                      );
                    },
                    child: const Text('Open real dock'),
                  ),
                ),
              ),
              bottomNavigationBar: AppBottomDock(
                selectedIndex: 0,
                onDestinationSelected: (_) {},
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.home, key: navIconKey),
                    label: 'Home',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.search),
                    label: 'Search',
                  ),
                ],
                miniPlayer: const SizedBox(
                  key: sourceMiniKey,
                  child: MiniPlayer(),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    final settledGap = _settledDockGap(tester);
    final settledSourceMiniRect = tester.getRect(find.byKey(sourceMiniKey));
    await tester.tap(find.text('Open real dock'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final firstPushMiniRect = _dockFlightRect(tester);
    expect(firstPushMiniRect.top, closeTo(settledSourceMiniRect.top, 1));
    expect(firstPushMiniRect.bottom, closeTo(settledSourceMiniRect.bottom, 1));
    final pushGaps = <double>[_dockFlightGap(tester)];
    tester.view.padding = const FakeViewPadding();
    Rect lastPushMiniRect = firstPushMiniRect;
    for (var frame = 0; frame < 600; frame++) {
      if (find
          .byKey(appBottomDockMiniPlayerHandoffRootKey)
          .evaluate()
          .isEmpty) {
        break;
      }
      lastPushMiniRect = _dockFlightRect(tester);
      pushGaps.add(_dockFlightGap(tester));
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsNothing);
    expect(
      pushGaps.reduce(math.max) - pushGaps.reduce(math.min),
      lessThan(1),
      reason: 'Push gaps: $pushGaps',
    );
    for (final gap in pushGaps) {
      expect(gap, closeTo(settledGap, 1));
    }

    expect(
      find.byKey(const ValueKey('mini-player-dismissible')),
      findsOneWidget,
    );
    final landedTargetMiniRect = tester.getRect(
      find.byKey(const ValueKey('mini-player-dismissible')),
    );
    expect(landedTargetMiniRect.top, closeTo(lastPushMiniRect.top, 1));

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump();
    final firstPopMiniRect = _dockFlightRect(tester);
    expect(firstPopMiniRect.top, closeTo(landedTargetMiniRect.top, 1));
    final popGaps = <double>[_dockFlightGap(tester)];
    Rect lastPopMiniRect = firstPopMiniRect;
    for (var frame = 0; frame < 600; frame++) {
      if (find
          .byKey(appBottomDockMiniPlayerHandoffRootKey)
          .evaluate()
          .isEmpty) {
        break;
      }
      lastPopMiniRect = _dockFlightRect(tester);
      popGaps.add(_dockFlightGap(tester));
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsNothing);
    expect(
      popGaps.reduce(math.max) - popGaps.reduce(math.min),
      lessThan(1),
      reason: 'Pop gaps: $popGaps',
    );
    for (final gap in popGaps) {
      expect(gap, closeTo(settledGap, 1));
    }
    final gapBeforeHandoff = popGaps.last;
    final sourceMini = tester.getRect(find.byKey(sourceMiniKey));
    final sourceIcon = tester.getRect(find.byKey(navIconKey));
    expect(sourceMini.top, closeTo(lastPopMiniRect.top, 1));
    expect(sourceIcon.top - sourceMini.bottom, closeTo(gapBeforeHandoff, 1));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android predictive back preserves dock gap and can cancel', (
    tester,
  ) async {
    _configurePhoneViewport(tester, bottomInset: 34);
    const sourceMiniKey = ValueKey('real-gap-source-mini');
    const targetMiniKey = ValueKey('real-gap-target-mini');
    const navIconKey = ValueKey('real-gap-navigation-icon');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(null),
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
                  child: const Text('Open predictive details'),
                ),
              ),
            ),
            bottomNavigationBar: AppBottomDock(
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home, key: navIconKey),
                  label: 'Home',
                ),
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

    await tester.pumpAndSettle();
    final settledGap = _settledDockGap(tester);
    await tester.tap(find.text('Open predictive details'));
    await tester.pumpAndSettle();
    final route =
        ModalRoute.of(tester.element(find.byKey(targetMiniKey)))!
            as PageRoute<void>;
    tester.view.padding = const FakeViewPadding();

    final sourceSnapshot = _snapshotControllerFor(tester, sourceMiniKey);
    var sourceRasters = 0;
    final onCreate = ui.Image.onCreate;
    ui.Image.onCreate = (image) {
      onCreate?.call(image);
      if (sourceSnapshot.allowSnapshotting &&
          image.width == 390 &&
          image.height == 844) {
        sourceRasters++;
      }
    };
    addTearDown(() => ui.Image.onCreate = onCreate);

    final targetSnapshot = _snapshotControllerFor(tester, targetMiniKey);
    final settledTarget = tester.getRect(find.byKey(targetMiniKey));
    route.handleStartBackGesture(progress: 1);
    await tester.pump();
    expect(route.animation!.value, 1);
    expect(targetSnapshot.allowSnapshotting, isFalse);
    expect(_dockFlightRect(tester), settledTarget);
    await tester.pump();
    expect(targetSnapshot.allowSnapshotting, isTrue);
    final cancelledGaps = <double>[];
    for (final progress in [0.99, 0.75, 0.5, 0.25]) {
      route.handleUpdateBackGestureProgress(progress: progress);
      await tester.pump();
      cancelledGaps.add(_dockFlightGap(tester));
    }
    expect(
      cancelledGaps,
      everyElement(closeTo(settledGap, 1)),
      reason: 'Predictive-back cancel gaps: $cancelledGaps',
    );
    route.handleCancelBackGesture();
    await tester.pumpAndSettle();
    expect(find.byKey(targetMiniKey), findsOneWidget);
    expect(find.byKey(sourceMiniKey), findsNothing);
    expect(sourceRasters, 0);

    route.handleStartBackGesture(progress: 1);
    final committedGaps = <double>[];
    for (final progress in [0.99, 0.75, 0.5, 0.25]) {
      route.handleUpdateBackGestureProgress(progress: progress);
      await tester.pump();
      committedGaps.add(_dockFlightGap(tester));
    }
    expect(
      committedGaps,
      everyElement(closeTo(settledGap, 1)),
      reason: 'Predictive-back commit gaps: $committedGaps',
    );
    route.handleCommitBackGesture();
    await tester.pump();
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(sourceSnapshot.allowSnapshotting, isFalse);
    }
    await tester.pumpAndSettle();
    expect(find.byKey(sourceMiniKey), findsOneWidget);
    expect(find.byKey(targetMiniKey), findsNothing);
    expect(_settledDockGap(tester), closeTo(settledGap, 1));
    expect(
      sourceRasters,
      0,
      reason: 'Dock gesture settling must not rasterize the source.',
    );
    expect(tester.takeException(), isNull);
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
          theme: AppTheme.lightTheme(null),
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
    await tester.pump(const Duration(milliseconds: 200));

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
        theme: AppTheme.lightTheme(null),
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

    expect(find.byType(AppBottomDockMiniPlayer), findsNothing);
    await tester.tap(find.text('Open without playback'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byType(AppBottomDockMiniPlayer), findsNothing);
    expect(
      tester.getTopLeft(find.byType(NavigationBar)).dy,
      closeTo(786 + 58 * Curves.ease.transform(0.5), 0.1),
    );
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
        theme: AppTheme.lightTheme(null),
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
                AppBottomDockMiniPlayer.source(
                  child: SizedBox(
                    key: sourceMiniKey,
                    width: double.infinity,
                    height: 72,
                  ),
                ),
                AppBottomDockTabBar.source(
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

  final dragEntry = ValueVariant<bool>({false, true});
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
        child: MaterialApp(
          theme: AppTheme.lightTheme(null),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const GlobalAudioPlayerWrapper.workDetails(
            child: Scaffold(body: Text('Landed work details')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    TestGesture? opening;
    if (dragEntry.currentValue!) {
      opening = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey('mini-player-upward-launcher')),
        ),
      );
      await opening.moveBy(const Offset(0, -220));
    } else {
      await tester.tap(find.byKey(const ValueKey('mini-player-artwork-frame')));
    }
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

    await opening?.up();
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    final closing = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('compact-header-dismiss-surface')),
      ),
    );
    await closing.moveBy(const Offset(0, 20));
    await closing.moveBy(const Offset(0, 40));
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
    await closing.cancel();
    await tester.pumpAndSettle();
    final finalClosing = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('compact-header-dismiss-surface')),
      ),
    );
    await finalClosing.moveBy(const Offset(0, 20));
    await finalClosing.moveBy(const Offset(0, 40));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      find.byKey(const ValueKey('player-artwork-flight-frame')),
      findsOneWidget,
    );
    await finalClosing.moveBy(const Offset(0, 200));
    await finalClosing.up();
    await tester.pumpAndSettle();
    expect(find.byType(AppBottomDockMiniPlayer), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Hero && widget.tag == 'app-bottom-dock-mini-player',
      ),
      findsNothing,
    );
    expect(find.text('Landed work details'), findsOneWidget);
    if (dragEntry.currentValue!) {
      final shortOpening = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey('mini-player-upward-launcher')),
        ),
      );
      await shortOpening.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 200));
      await shortOpening.up();
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Hero && widget.tag == 'app-bottom-dock-mini-player',
        ),
        findsNothing,
      );
    }
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  }, variant: dragEntry);
}

class _WorkDetailsTarget extends StatelessWidget {
  const _WorkDetailsTarget({required this.miniPlayerKey, this.scaffoldKey});

  final Key? miniPlayerKey;
  final Key? scaffoldKey;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: scaffoldKey,
      body: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.white),
          if (miniPlayerKey case final miniPlayerKey?)
            Align(
              alignment: Alignment.bottomCenter,
              child: AppBottomDockMiniPlayer.target(
                child: SizedBox(
                  key: miniPlayerKey,
                  width: double.infinity,
                  height: 72,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

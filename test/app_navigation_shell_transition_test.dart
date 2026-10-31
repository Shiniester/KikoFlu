import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/search_result_provider.dart';
import 'package:kikoeru_flutter/src/providers/update_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/screens/search_result_screen.dart';
import 'package:kikoeru_flutter/src/screens/work_detail_screen.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_navigation_scope.dart';
import 'package:kikoeru_flutter/src/widgets/app_navigation_shell.dart';
import 'package:kikoeru_flutter/src/widgets/cover_preview_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/enhanced_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_lyrics_surface.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';
import 'package:kikoeru_flutter/src/widgets/responsive_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/tag_chip.dart';
import 'package:kikoeru_flutter/src/widgets/works_grid_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = AudioTrack(
  id: 'shell-transition-track',
  title: 'Audio',
  url: 'https://example.invalid/audio.mp3',
);

class _EmptyTagSearchApi extends KikoeruApiService {
  _EmptyTagSearchApi({this.withResults = false});

  final bool withResults;
  int searchCalls = 0;
  Completer<void>? nextPageGate;
  CancelToken? blockedToken;

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
  }) async {
    searchCalls++;
    final gate = nextPageGate;
    if (page == 2 && gate != null) {
      nextPageGate = null;
      blockedToken = cancelToken;
      await gate.future;
    }
    return {
      'works': withResults
          ? List.generate(
              30,
              (index) => {
                'id': page * 100 + index,
                'title': 'Match $page-$index',
              },
            )
          : <dynamic>[],
      'pagination': {'totalCount': withResults ? 60 : 0},
    };
  }

  @override
  Future<Map<String, dynamic>> getWork(
    int id, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async => {'id': id, 'title': 'Match $id'};

  @override
  Future<List<dynamic>> getWorkTracks(
    int id, {
    bool forceRefresh = false,
  }) async => [];
}

Future<AppNavigationController> _pumpShell(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  bool reducedMotion = false,
  bool withTrack = true,
  bool fakeTagSearch = false,
  bool tagSearchResults = false,
  int initialTabIndex = 0,
  ThemeData? theme,
  FakeViewPadding safePadding = FakeViewPadding.zero,
  Widget Function(AppNavigationController)? homeBuilder,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = safePadding;
  tester.view.viewPadding = safePadding;
  addTearDown(tester.view.reset);
  final navigation = AppNavigationController();
  navigation.selectTab(initialTabIndex);
  addTearDown(navigation.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (fakeTagSearch)
          kikoeruApiServiceProvider.overrideWith(
            (ref) => _EmptyTagSearchApi(withResults: tagSearchResults),
          ),
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
        theme: theme,
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        navigatorObservers: [navigation],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: RepaintBoundary(
            key: const ValueKey('shell-paint'),
            child: AppNavigationShell(controller: navigation, child: child!),
          ),
        ),
        home:
            homeBuilder?.call(navigation) ??
            const Scaffold(
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
  Widget? child,
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
          : SizedBox.expand(
              key: const ValueKey('player-viewport'),
              child: child,
            ),
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

  for (final withTrack in [false, true]) {
    testWidgets('portrait sheet covers the Dock (track=$withTrack)', (
      tester,
    ) async {
      await _pumpShell(
        tester,
        withTrack: withTrack,
        safePadding: const FakeViewPadding(bottom: 24),
      );
      final context = tester.element(
        find.byKey(const ValueKey('home-viewport')),
      );
      var selected = false;
      unawaited(
        showResponsiveBottomSheet<void>(
          context: context,
          builder: (sheetContext) => BottomSheetMenu(
            children: [
              ListTile(
                title: const Text('Sheet action'),
                onTap: () {
                  selected = true;
                  Navigator.of(sheetContext).pop();
                },
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final sheet = find.byKey(const ValueKey('responsive-sheet-surface'));
      expect(tester.getRect(sheet).bottom, greaterThan(844));
      expect(find.text('Sheet action').hitTestable(), findsOneWidget);
      await tester.pumpAndSettle();

      final dock = tester.getRect(find.byType(AppBottomDock));
      final action = find.widgetWithText(ListTile, 'Sheet action');
      final actionRect = tester.getRect(action);
      expect(tester.getRect(sheet).bottom, closeTo(844, 0.1));
      expect(actionRect.center.dy, greaterThan(dock.top));
      expect(actionRect.bottom, closeTo(812, 0.1));
      expect(action.hitTestable(), findsOneWidget);

      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(selected, isTrue);
      expect(find.text('Sheet action'), findsNothing);
      expect(find.byType(AppBottomDock).hitTestable(), findsOneWidget);
    });
  }

  for (final themedShape in [false, true]) {
    testWidgets('sheet corners retain the Dock (themedShape=$themedShape)', (
      tester,
    ) async {
      await _pumpShell(
        tester,
        safePadding: const FakeViewPadding(bottom: 24),
        theme: ThemeData(
          scaffoldBackgroundColor: Colors.blue,
          navigationBarTheme: const NavigationBarThemeData(
            backgroundColor: Colors.green,
            surfaceTintColor: Colors.transparent,
          ),
          bottomSheetTheme: BottomSheetThemeData(
            backgroundColor: Colors.red,
            elevation: 0,
            shape: themedShape
                ? const RoundedRectangleBorder(
                    borderRadius: BorderRadiusDirectional.only(
                      topStart: Radius.circular(24),
                      topEnd: Radius.circular(12),
                    ),
                  )
                : null,
          ),
        ),
      );
      final context = tester.element(
        find.byKey(const ValueKey('home-viewport')),
      );
      unawaited(
        showResponsiveBottomSheet<void>(
          context: context,
          maxWidth: 220,
          builder: (_) => const SizedBox(
            width: double.infinity,
            height: 40,
            child: Center(child: Text('Corner sheet')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final sheet = tester.getRect(
        find.byKey(const ValueKey('responsive-sheet-surface')),
      );
      expect(
        sheet.top,
        greaterThan(tester.getRect(find.byType(AppBottomDock)).top),
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('shell-paint')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          int pixelAt(double x, double y) =>
              pixels.getUint32(4 * (y.floor() * image.width + x.floor()));
          final dockColor = pixelAt(sheet.left - 2, sheet.top + 1);
          expect(pixelAt(sheet.left + 1, sheet.top + 1), dockColor);
          expect(pixelAt(sheet.right - 2, sheet.top + 1), dockColor);
          expect(pixelAt(sheet.center.dx, sheet.top + 1), isNot(dockColor));
        } finally {
          image.dispose();
        }
      });
      await tester.tapAt(sheet.topLeft + const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(find.text('Corner sheet'), findsNothing);
    });
  }

  testWidgets('a narrow sheet leaves the rest of a wide Dock protected', (
    tester,
  ) async {
    final navigation = await _pumpShell(
      tester,
      size: const Size(800, 1200),
      safePadding: const FakeViewPadding(bottom: 24),
    );
    final context = tester.element(find.byKey(const ValueKey('home-viewport')));
    unawaited(
      showResponsiveBottomSheet<void>(
        context: context,
        maxWidth: 360,
        builder: (_) => const BottomSheetMenu(
          children: [ListTile(title: Text('Narrow sheet action'))],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Narrow sheet action').hitTestable(), findsOneWidget);

    await tester.tapAt(const Offset(20, 1180));
    await tester.pumpAndSettle();
    expect(find.text('Narrow sheet action'), findsNothing);
    expect(navigation.selectedIndex, 0);
  });

  testWidgets('a sheet covers the Dock with reduced motion', (tester) async {
    await _pumpShell(
      tester,
      reducedMotion: true,
      safePadding: const FakeViewPadding(bottom: 24),
    );
    final context = tester.element(find.byKey(const ValueKey('home-viewport')));
    unawaited(
      showResponsiveBottomSheet<void>(
        context: context,
        builder: (_) => const BottomSheetMenu(
          children: [ListTile(title: Text('Reduced motion action'))],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reduced motion action').hitTestable(), findsOneWidget);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('responsive-sheet-surface')))
          .bottom,
      closeTo(844, 0.1),
    );
  });

  testWidgets('Dock clipping follows a sheet that changes height', (
    tester,
  ) async {
    await _pumpShell(tester, safePadding: const FakeViewPadding(bottom: 24));
    final context = tester.element(find.byKey(const ValueKey('home-viewport')));
    var expanded = false;
    var selected = false;
    unawaited(
      showResponsiveBottomSheet<void>(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (context, setState) => SizedBox(
            height: expanded ? 220 : 56,
            child: Center(
              child: TextButton(
                onPressed: expanded
                    ? () => selected = true
                    : () => setState(() => expanded = true),
                child: Text(expanded ? 'Expanded action' : 'Expand'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expand'));
    await tester.pumpAndSettle();

    final action = find.text('Expanded action');
    expect(tester.getCenter(action).dy, greaterThan(690));
    expect(tester.getCenter(action).dy, lessThan(764));
    expect(action.hitTestable(), findsOneWidget);
    await tester.tap(action);
    expect(selected, isTrue);
  });

  testWidgets('uncovered Dock remains protected by the sheet barrier', (
    tester,
  ) async {
    final navigation = await _pumpShell(
      tester,
      safePadding: const FakeViewPadding(bottom: 24),
    );
    final context = tester.element(find.byKey(const ValueKey('home-viewport')));
    unawaited(
      showResponsiveBottomSheet<void>(
        context: context,
        builder: (_) => const BottomSheetMenu(
          children: [ListTile(title: Text('Short sheet'))],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dock = tester.getRect(find.byType(AppBottomDock));
    final sheet = tester.getRect(
      find.byKey(const ValueKey('responsive-sheet-surface')),
    );
    expect(dock.top, lessThan(sheet.top));

    await tester.tapAt(Offset(20, dock.top + 5));
    await tester.pumpAndSettle();
    expect(find.text('Short sheet'), findsNothing);
    expect(navigation.selectedIndex, 0);
  });

  testWidgets('sheet state survives rotation with the Dock', (tester) async {
    await _pumpShell(tester, safePadding: const FakeViewPadding(bottom: 24));
    final context = tester.element(find.byKey(const ValueKey('home-viewport')));
    var selected = false;
    unawaited(
      showResponsiveBottomSheet<void>(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (context, setState) => CheckboxListTile(
            title: const Text('Keep choice'),
            value: selected,
            onChanged: (value) => setState(() => selected = value ?? false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep choice'));
    await tester.pump();
    expect(selected, isTrue);

    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(selected, isTrue);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('responsive-sheet-surface')))
          .right,
      closeTo(844, 0.1),
    );

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.text('Keep choice').hitTestable(), findsOneWidget);
    expect(selected, isTrue);
  });

  testWidgets('sheet stays usable above the keyboard with the Dock', (
    tester,
  ) async {
    await _pumpShell(tester, safePadding: const FakeViewPadding(bottom: 24));
    final context = tester.element(find.byKey(const ValueKey('home-viewport')));
    unawaited(
      showResponsiveBottomSheet<void>(
        context: context,
        builder: (_) => const BottomSheetMenu(
          children: [ListTile(title: Text('Keyboard sheet action'))],
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(
      tester
          .getRect(find.byKey(const ValueKey('responsive-sheet-surface')))
          .bottom,
      lessThanOrEqualTo(544),
    );
    expect(find.text('Keyboard sheet action').hitTestable(), findsOneWidget);

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(find.text('Keyboard sheet action').hitTestable(), findsOneWidget);
  });

  testWidgets('dialogs and sheets stay above an open Dock-covering sheet', (
    tester,
  ) async {
    await _pumpShell(tester, safePadding: const FakeViewPadding(bottom: 24));
    final context = tester.element(find.byKey(const ValueKey('home-viewport')));
    unawaited(
      showResponsiveBottomSheet<void>(
        context: context,
        builder: (sheetContext) => BottomSheetMenu(
          children: [
            ListTile(
              title: const Text('Open dialog'),
              onTap: () => showDialog<void>(
                context: sheetContext,
                builder: (dialogContext) => AlertDialog(
                  content: const Text('Nested dialog'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('Close dialog'),
                    ),
                  ],
                ),
              ),
            ),
            ListTile(
              title: const Text('Open another sheet'),
              onTap: () => showResponsiveBottomSheet<void>(
                context: sheetContext,
                builder: (nestedContext) => BottomSheetMenu(
                  children: [
                    ListTile(
                      title: const Text('Close nested sheet'),
                      onTap: () => Navigator.of(nestedContext).pop(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();
    expect(find.text('Close dialog').hitTestable(), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Nested dialog'), findsNothing);
    expect(find.text('Open another sheet').hitTestable(), findsOneWidget);

    await tester.tap(find.text('Open another sheet'));
    await tester.pumpAndSettle();
    expect(find.text('Close nested sheet').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Close nested sheet'));
    await tester.pumpAndSettle();
    expect(find.text('Open another sheet').hitTestable(), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Open another sheet'), findsNothing);
    expect(find.byType(AppBottomDock).hitTestable(), findsOneWidget);
  });

  testWidgets('a nested Navigator sheet covers the Dock and returns a result', (
    tester,
  ) async {
    final navigation = await _pumpShell(
      tester,
      safePadding: const FakeViewPadding(bottom: 24),
    );
    Future<String?>? result;
    unawaited(
      navigation.navigator!.push(
        MaterialPageRoute<void>(
          builder: (_) => Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () {
                    result = showResponsiveBottomSheet<String>(
                      context: context,
                      builder: (sheetContext) => BottomSheetMenu(
                        children: [
                          ListTile(
                            title: const Text('Nested action'),
                            onTap: () => Navigator.of(sheetContext).pop('done'),
                          ),
                        ],
                      ),
                    );
                  },
                  child: const Text('Open nested Navigator sheet'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open nested Navigator sheet'));
    await tester.pumpAndSettle();

    final action = find.text('Nested action');
    expect(
      tester.getCenter(action).dy,
      greaterThan(tester.getRect(find.byType(AppBottomDock)).top),
    );
    expect(action.hitTestable(), findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(await result, 'done');
    expect(find.text('Open nested Navigator sheet'), findsOneWidget);

    await tester.tap(find.text('Open nested Navigator sheet'));
    await tester.pumpAndSettle();
    final firstSheetContext = tester.element(find.text('Nested action'));
    unawaited(
      showResponsiveBottomSheet<void>(
        context: firstSheetContext,
        builder: (sheetContext) => BottomSheetMenu(
          children: [
            ListTile(
              title: const Text('Second nested sheet'),
              onTap: () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final nestedNavigator = Navigator.of(
      tester.element(find.text('Second nested sheet')),
    );
    unawaited(
      nestedNavigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Nested page above sheet')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
    nestedNavigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('Second nested sheet').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Second nested sheet'));
    await tester.pumpAndSettle();
    expect(find.text('Nested action').hitTestable(), findsOneWidget);

    unawaited(
      navigation.navigator!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Page above nested sheet')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
    navigation.navigator!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Nested action').hitTestable(), findsOneWidget);

    final dock = tester.getRect(find.byType(AppBottomDock));
    await tester.tapAt(Offset(20, dock.top + 5));
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(find.text('Open nested Navigator sheet'), findsOneWidget);
  });

  testWidgets('a page above a sheet restores Dock interaction', (tester) async {
    final navigation = await _pumpShell(
      tester,
      safePadding: const FakeViewPadding(bottom: 24),
    );
    final context = tester.element(find.byKey(const ValueKey('home-viewport')));
    unawaited(
      showResponsiveBottomSheet<void>(
        context: context,
        builder: (_) => const BottomSheetMenu(
          children: [ListTile(title: Text('Underlying sheet'))],
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      navigation.navigator!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Page above sheet')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Page above sheet'), findsOneWidget);
    expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
    navigation.navigator!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Underlying sheet').hitTestable(), findsOneWidget);
  });

  for (final nested in [false, true]) {
    testWidgets(
      'tab sheets follow the active tab and its pages (nested=$nested)',
      (tester) async {
        final navigation = await _pumpShell(
          tester,
          safePadding: const FakeViewPadding(bottom: 24),
          homeBuilder: (navigation) => ListenableBuilder(
            listenable: navigation,
            builder: (context, _) => IndexedStack(
              index: navigation.selectedIndex,
              children: [
                for (var index = 0; index < 2; index++)
                  Navigator(
                    key: navigation.tabNavigatorKey(index),
                    observers: [navigation.tabObserver(index)],
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (context) {
                        Widget content(BuildContext context) => Scaffold(
                          body: TextButton(
                            onPressed: () => showResponsiveBottomSheet<void>(
                              context: context,
                              builder: (_) => const BottomSheetMenu(
                                children: [
                                  ListTile(title: Text('Tab sheet action')),
                                ],
                              ),
                            ),
                            child: Text('Open tab $index sheet'),
                          ),
                        );
                        if (nested && index == 0) {
                          return Navigator(
                            onGenerateRoute: (_) =>
                                MaterialPageRoute<void>(builder: content),
                          );
                        }
                        return content(context);
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
        await tester.tap(find.text('Open tab 0 sheet'));
        await tester.pumpAndSettle();
        expect(find.text('Tab sheet action').hitTestable(), findsOneWidget);

        navigation.selectTab(1);
        await tester.pumpAndSettle();
        expect(find.text('Open tab 1 sheet'), findsOneWidget);
        expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
        navigation.selectTab(0);
        await tester.pumpAndSettle();
        expect(find.text('Tab sheet action').hitTestable(), findsOneWidget);

        unawaited(
          navigation.navigator!.push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  const Scaffold(body: Text('Root page above tab sheet')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
        navigation.navigator!.pop();
        await tester.pumpAndSettle();
        expect(find.text('Tab sheet action').hitTestable(), findsOneWidget);

        final tabNavigator = navigation.tabNavigator(0)!;
        unawaited(
          tabNavigator.push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  const Scaffold(body: Text('Tab page above sheet')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
        tabNavigator.pop();
        await tester.pumpAndSettle();
        expect(find.text('Tab sheet action').hitTestable(), findsOneWidget);
      },
    );
  }

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

  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    testWidgets('navigation chrome does not rebuild on each frame at $size', (
      tester,
    ) async {
      final navigation = await _pumpShell(tester, size: size);
      var dockBuilds = 0;
      var railBuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is AppBottomDock) dockBuilds++;
        if (element.widget is NavigationRail) railBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      _openPlayer(navigation);
      await tester.pump();
      final buildsAtAnimationStart = size.width > size.height
          ? railBuilds
          : dockBuilds;

      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(
        size.width > size.height ? railBuilds : dockBuilds,
        buildsAtAnimationStart,
      );
    });
  }

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
    for (final page in ['cover preview', 'tag search', 'lyric preview']) {
      testWidgets('player keeps its viewport under $page at $size', (
        tester,
      ) async {
        final navigation = await _pumpShell(
          tester,
          size: size,
          fakeTagSearch: page == 'tag search',
        );
        _openPlayer(
          navigation,
          child: page == 'tag search'
              ? const Center(
                  child: TagChip(tag: Tag(id: 999999, name: 'Test tag')),
                )
              : null,
        );
        await tester.pumpAndSettle();
        final player = find.byKey(
          const ValueKey('player-viewport'),
          skipOffstage: false,
        );
        final playerContext = tester.element(player);
        if (page == 'cover preview') {
          unawaited(
            CoverPreviewDialog.show(playerContext, localPath: 'missing.jpg'),
          );
        } else if (page == 'tag search') {
          await tester.tap(find.text('Test tag'));
        } else {
          unawaited(
            Navigator.of(playerContext).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Lyric preview')),
              ),
            ),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(navigation.navigationVisible, isFalse);
        expect(tester.getSize(player), size);
        await tester.pumpAndSettle();
        expect(
          page == 'cover preview'
              ? find.byType(CoverPreviewDialog)
              : page == 'tag search'
              ? find.byType(SearchResultScreen)
              : find.text('Lyric preview'),
          findsOneWidget,
        );
        if (page == 'tag search') {
          expect(
            tester
                .widget<SearchResultScreen>(find.byType(SearchResultScreen))
                .searchParams?['tagId'],
            999999,
          );
        }
        expect(find.byType(AppBottomDock), findsNothing);
        expect(find.byType(NavigationRail), findsNothing);
        expect(tester.getSize(player), size);

        navigation.navigator!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(navigation.navigationVisible, isFalse);
        expect(tester.getSize(player), size);
        await tester.pumpAndSettle();
        expect(navigation.navigationVisible, isFalse);
        expect(tester.getSize(player), size);
        navigation.navigator!.pop();
        await tester.pumpAndSettle();
        expect(navigation.navigationVisible, isTrue);
        expect(
          size.width > size.height
              ? find.byType(NavigationRail)
              : find.byType(AppBottomDock),
          findsOneWidget,
        );
      });
    }
  }

  testWidgets('rapid back keeps the Dock hidden until the player closes', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester);
    _openPlayer(navigation);
    await tester.pumpAndSettle();
    final player = find.byKey(const ValueKey('player-viewport'));
    unawaited(
      CoverPreviewDialog.show(tester.element(player), localPath: 'missing.jpg'),
    );
    await tester.pumpAndSettle();

    navigation.navigator!.pop();
    await tester.pump();
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(navigation.navigationVisible, isFalse);
    expect(find.byType(AppBottomDock), findsNothing);
    expect(tester.getSize(player), const Size(390, 844));

    await tester.pumpAndSettle();
    expect(navigation.navigationVisible, isTrue);
    expect(find.byType(AppBottomDock), findsOneWidget);
  });

  for (final pending in [false, true]) {
    testWidgets('player search preserves results (pending=$pending)', (
      tester,
    ) async {
      var audioVisited = false;
      final navigation = await _pumpShell(
        tester,
        fakeTagSearch: true,
        tagSearchResults: true,
        initialTabIndex: 2,
        homeBuilder: (navigation) => ListenableBuilder(
          listenable: navigation,
          builder: (_, __) {
            audioVisited |= navigation.selectedIndex == appAudioTabIndex;
            return IndexedStack(
              index: navigation.selectedIndex,
              children: [
                for (var index = 0; index < appTabCount; index++)
                  if (index == appAudioTabIndex && !audioVisited)
                    const SizedBox.shrink()
                  else
                    Navigator(
                      key: navigation.tabNavigatorKey(index),
                      observers: [navigation.tabObserver(index)],
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => Scaffold(body: Text('Tab $index')),
                      ),
                    ),
              ],
            );
          },
        ),
      );
      expect(navigation.tabNavigator(appAudioTabIndex), isNull);
      _openPlayer(
        navigation,
        child: const Center(
          child: TagChip(tag: Tag(id: 999999, name: 'Test tag')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test tag'));
      await tester.pumpAndSettle();

      var grid = tester.widget<WorksGridView>(find.byType(WorksGridView));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorksGridView)),
      );
      final api =
          container.read(kikoeruApiServiceProvider) as _EmptyTagSearchApi;
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      if (pending) {
        api.nextPageGate = gate;
        unawaited(container.read(searchResultProvider.notifier).goToPage(2));
        await tester.pump();
      } else {
        await container.read(searchResultProvider.notifier).goToPage(2);
        await tester.pumpAndSettle();
      }
      grid = tester.widget<WorksGridView>(find.byType(WorksGridView));
      grid.scrollController!.jumpTo(250);
      if (pending) {
        await tester.pump();
      } else {
        await tester.pumpAndSettle();
      }
      final offset = grid.scrollController!.offset;
      final calls = api.searchCalls;
      await tester.tap(find.byType(EnhancedWorkCard).hitTestable().first);
      await tester.pump();
      await tester.pump();
      if (pending) expect(api.blockedToken!.isCancelled, isTrue);
      await tester.pumpAndSettle();

      expect(find.byType(WorkDetailScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-viewport'), skipOffstage: false),
        findsNothing,
      );
      expect(navigation.selectedIndex, appAudioTabIndex);
      expect(find.byType(AppBottomDock), findsOneWidget);
      navigation.selectTab(1);
      await tester.pumpAndSettle();
      expect(find.text('Tab 1'), findsOneWidget);
      navigation.selectTab(appAudioTabIndex);
      await tester.pumpAndSettle();
      expect(find.byType(WorkDetailScreen), findsOneWidget);

      navigation.tabNavigator(appAudioTabIndex)!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(SearchResultScreen), findsOneWidget);
      final restoredContext = tester.element(find.byType(WorksGridView));
      expect(
        ProviderScope.containerOf(
          restoredContext,
        ).read(searchResultProvider).currentPage,
        2,
      );
      expect(
        tester
            .widget<WorksGridView>(find.byType(WorksGridView))
            .scrollController!
            .offset,
        closeTo(offset, 0.1),
      );
      expect(api.searchCalls, calls + (pending ? 1 : 0));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('work search without a player keeps its normal return path', (
    tester,
  ) async {
    final navigation = await _pumpShell(
      tester,
      fakeTagSearch: true,
      tagSearchResults: true,
      homeBuilder: (_) => const Scaffold(
        body: Center(
          child: TagChip(tag: Tag(id: 999999, name: 'Test tag')),
        ),
      ),
    );
    await tester.tap(find.text('Test tag'));
    await tester.pumpAndSettle();
    final grid = tester.widget<WorksGridView>(find.byType(WorksGridView));
    grid.scrollController!.jumpTo(250);
    await tester.pumpAndSettle();
    final offset = grid.scrollController!.offset;
    await tester.tap(find.byType(EnhancedWorkCard).hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.byType(WorkDetailScreen), findsOneWidget);
    expect(find.byType(AppBottomDock), findsOneWidget);
    navigation.navigator!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(SearchResultScreen), findsOneWidget);
    expect(grid.scrollController!.offset, closeTo(offset, 0.1));
    expect(tester.takeException(), isNull);
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

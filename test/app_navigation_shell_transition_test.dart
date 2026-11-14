import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:image/image.dart' as img;
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/comics/comic_downloads.dart';
import 'package:kikoeru_flutter/src/comics/comic_library.dart';
import 'package:kikoeru_flutter/src/comics/comic_models.dart';
import 'package:kikoeru_flutter/src/comics/comic_providers.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_download_screen.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/models/user.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/search_result_provider.dart';
import 'package:kikoeru_flutter/src/providers/update_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/local_file_url.dart';
import 'package:kikoeru_flutter/src/utils/theme.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_settings_screen.dart';
import 'package:kikoeru_flutter/src/screens/search_result_screen.dart';
import 'package:kikoeru_flutter/src/screens/work_detail_screen.dart';
import 'package:kikoeru_flutter/src/screens/offline_work_detail_screen.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_navigation_scope.dart';
import 'package:kikoeru_flutter/src/widgets/app_navigation_shell.dart';
import 'package:kikoeru_flutter/src/widgets/cover_preview_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/enhanced_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:kikoeru_flutter/src/widgets/playlist_add_works_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_lyrics_surface.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_cover_widget.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_vertical_gestures.dart';
import 'package:kikoeru_flutter/src/widgets/responsive_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/subtitle_library_folder_browser_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/tag_chip.dart';
import 'package:kikoeru_flutter/src/widgets/text_preview_screen.dart';
import 'package:kikoeru_flutter/src/widgets/works_grid_view.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_cover_frame.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = AudioTrack(
  id: 'shell-transition-track',
  title: 'Audio',
  url: 'https://example.invalid/audio.mp3',
);

Widget _tabHome(
  AppNavigationController navigation,
  Widget child, {
  int index = 0,
}) => NavigatorPopHandler<void>(
  onPopWithResult: (_) => navigation.tabNavigator(index)?.maybePop<void>(),
  child: Navigator(
    key: navigation.tabNavigatorKey(index),
    observers: [
      navigation.tabObserver(index),
      navigation.tabHeroController(index),
    ],
    onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => child),
  ),
);

class _StatefulHomeProbe extends StatefulWidget {
  const _StatefulHomeProbe(this.navigation);

  final AppNavigationController navigation;

  @override
  State<_StatefulHomeProbe> createState() => _StatefulHomeProbeState();
}

class _StatefulHomeProbeState extends State<_StatefulHomeProbe> {
  @override
  Widget build(BuildContext context) => _tabHome(
    widget.navigation,
    const Scaffold(body: SizedBox.expand(key: ValueKey('home-viewport'))),
  );
}

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

class _OfflineAuthNotifier extends AuthNotifier {
  _OfflineAuthNotifier() : super(KikoeruApiService()) {
    state = const AuthState(
      currentUser: User(name: 'Offline'),
      error: 'offline',
    );
  }
}

class _ComicTaskLibrary extends ComicLibrary {
  @override
  Future<List<Map<String, dynamic>>> loadTasks() async => [];
}

Future<AppNavigationController> _pumpShell(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  bool reducedMotion = false,
  bool withTrack = true,
  bool offline = false,
  Stream<AudioTrack?>? trackStream,
  Stream<PlayerState>? playerStateStream,
  bool fakeTagSearch = false,
  bool tagSearchResults = false,
  int initialTabIndex = 0,
  ThemeData? theme,
  TextScaler? textScaler,
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
  final appTheme = AppTheme.lightTheme(null);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (offline) authProvider.overrideWith((ref) => _OfflineAuthNotifier()),
        if (fakeTagSearch)
          kikoeruApiServiceProvider.overrideWith(
            (ref) => _EmptyTagSearchApi(withResults: tagSearchResults),
          ),
        currentTrackProvider.overrideWith(
          (ref) => trackStream ?? Stream.value(withTrack ? _track : null),
        ),
        showUpdateRedDotProvider.overrideWith((ref) => false),
        positionProvider.overrideWith(
          (ref) => Stream.value(const Duration(seconds: 30)),
        ),
        durationProvider.overrideWith(
          (ref) => Stream.value(const Duration(minutes: 4)),
        ),
        playerStateProvider.overrideWith(
          (ref) =>
              playerStateStream ??
              Stream.value(PlayerState(false, ProcessingState.ready)),
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
        theme: (theme ?? appTheme).copyWith(
          pageTransitionsTheme: appTheme.pageTransitionsTheme,
        ),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        navigatorObservers: [navigation],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion, textScaler: textScaler),
          child: RepaintBoundary(
            key: const ValueKey('shell-paint'),
            child: AppNavigationShell(controller: navigation, child: child!),
          ),
        ),
        home:
            homeBuilder?.call(navigation) ??
            _tabHome(
              navigation,
              Scaffold(
                body: const SizedBox.expand(key: ValueKey('home-viewport')),
                bottomNavigationBar: offline
                    ? const SafeArea(top: false, child: SizedBox(height: 96))
                    : null,
              ),
              index: initialTabIndex,
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
  Directory? coverPreviewCache;
  tearDownAll(() async {
    if (coverPreviewCache == null) return;
    await coverPreviewCache!.delete(recursive: true);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    for (final withInsets in [false, true]) {
      for (final check in ['center', 'zoom']) {
        testWidgets(
          'cover preview full-window $check at $size (insets=$withInsets)',
          (tester) async {
            final bytes = Uint8List.fromList(
              img.encodePng(
                img.fill(
                  img.Image(width: 120, height: 120),
                  color: img.ColorRgb8(0, 170, 0),
                ),
              ),
            );
            final navigation = await _pumpShell(
              tester,
              size: size,
              safePadding: !withInsets
                  ? FakeViewPadding.zero
                  : size.width > size.height
                  ? const FakeViewPadding(left: 44, bottom: 24)
                  : const FakeViewPadding(top: 32, bottom: 24),
              homeBuilder: (navigation) => _tabHome(
                navigation,
                Scaffold(
                  body: SizedBox.expand(
                    key: const ValueKey('full-window-preview-underlay'),
                    child: Builder(
                      builder: (context) => Center(
                        child: TextButton(
                          key: const ValueKey('open-full-window-preview'),
                          onPressed: () => unawaited(
                            CoverPreviewDialog.show(
                              context,
                              imageBytes: bytes,
                              heroTag: 'full-window-cover',
                            ),
                          ),
                          child: PlayerCoverPreviewHero(
                            tag: 'full-window-cover',
                            cornerRadius: 12,
                            child: SizedBox(
                              width: 120,
                              height: 120,
                              child: Image.memory(bytes),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            final opener = find.byKey(
              const ValueKey('open-full-window-preview'),
            );
            final underlay = find.byKey(
              const ValueKey('full-window-preview-underlay'),
            );
            final underlayRect = tester.getRect(underlay);
            await tester.runAsync(
              () => precacheImage(MemoryImage(bytes), tester.element(opener)),
            );
            await tester.tap(opener);
            await tester.pumpAndSettle();
            final viewport = find.byKey(
              const ValueKey('cover-preview-background'),
            );
            final frame = find.byKey(
              const ValueKey('cover-preview-image-frame'),
            );
            if (check == 'center') {
              expect(tester.getRect(viewport), Offset.zero & size);
              expect(tester.getCenter(frame), size.center(Offset.zero));
            } else {
              final viewer = find.byKey(
                const ValueKey('cover-preview-interactive-viewer'),
              );
              final center = tester.getCenter(viewer);
              final left = await tester.createGesture();
              final right = await tester.createGesture();
              await left.down(center - const Offset(20, 0));
              await right.down(center + const Offset(20, 0));
              await tester.pump();
              await left.moveTo(center - const Offset(120, 0));
              await right.moveTo(center + const Offset(120, 0));
              await tester.pump();
              await left.up();
              await right.up();
              await tester.pumpAndSettle();
              expect(
                tester
                    .widget<InteractiveViewer>(viewer)
                    .transformationController!
                    .value
                    .getMaxScaleOnAxis(),
                greaterThan(1),
              );
              final transform = tester
                  .widget<InteractiveViewer>(viewer)
                  .transformationController!;
              final beforePan = transform.value.getTranslation();
              await tester.dragFrom(
                Offset(size.width / 2, size.height - 8),
                const Offset(0, -40),
              );
              await tester.pumpAndSettle();
              expect(transform.value.getTranslation(), isNot(beforePan));
              await tester.runAsync(() async {
                final boundary = tester.renderObject<RenderRepaintBoundary>(
                  find.byKey(const ValueKey('shell-paint')),
                );
                final image = await boundary.toImage();
                try {
                  final pixels = (await image.toByteData(
                    format: ui.ImageByteFormat.rawRgba,
                  ))!;
                  for (final point in [
                    Offset(size.width / 2, size.height - 8),
                    if (size.width > size.height) Offset(8, size.height / 2),
                  ]) {
                    final offset =
                        4 * (point.dy.floor() * image.width + point.dx.floor());
                    expect(pixels.getUint32(offset), 0x00aa00ff);
                  }
                } finally {
                  image.dispose();
                }
              });
            }
            expect(tester.getRect(underlay), underlayRect);
            var closingUnderlayRect = underlayRect;
            if (check == 'center') {
              final rotatedSize = Size(size.height, size.width);
              tester.view.physicalSize = rotatedSize;
              await tester.pumpAndSettle();
              expect(tester.getRect(viewport), Offset.zero & rotatedSize);
              expect(tester.getCenter(frame), rotatedSize.center(Offset.zero));
              closingUnderlayRect = tester.getRect(underlay);
            }
            Navigator.of(tester.element(find.byType(CoverPreviewDialog))).pop();
            await tester.pumpAndSettle();
            expect(navigation.navigationVisible, isTrue);
            expect(tester.getRect(underlay), closingUnderlayRect);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    for (final offline in [false, true]) {
      testWidgets(
        'detail cover preview preserves layout and system bars at $size (offline=$offline)',
        (tester) async {
          final cacheDirectory = coverPreviewCache ??= Directory.systemTemp
              .createTempSync('detail-cover-preview-');
          const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            pathChannel,
            (_) async => cacheDirectory.path,
          );
          final previousCache = CachedNetworkImageProvider.defaultCacheManager;
          CacheService.installImageCacheManager();
          addTearDown(() {
            CachedNetworkImageProvider.defaultCacheManager = previousCache;
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              pathChannel,
              null,
            );
          });
          final systemModes = <Object?>[];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'SystemChrome.setEnabledSystemUIMode' ||
                  call.method == 'SystemChrome.setPreferredOrientations') {
                systemModes.add(call.arguments);
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          const work = Work(id: 42, title: 'Cover preview work');
          final navigation = await _pumpShell(
            tester,
            size: size,
            fakeTagSearch: true,
          );
          final auth = ProviderScope.containerOf(
            navigation.navigator!.context,
          ).read(authProvider);
          await tester.runAsync(() async {
            await CacheService.imageCacheManager.putFile(
              work.getCoverImageUrl(auth.host ?? '', token: auth.token ?? ''),
              await File('assets/icons/app_icon_opaque.png').readAsBytes(),
              key: 'work_cover_${work.id}',
              fileExtension: 'png',
            );
          });
          if (offline) {
            await tester.runAsync(
              () => precacheImage(
                FileImage(File('assets/icons/app_icon_opaque.png')),
                navigation.navigator!.context,
              ),
            );
          }
          unawaited(
            navigation.navigator!.push(
              MaterialPageRoute<void>(
                builder: (_) => offline
                    ? const OfflineWorkDetailScreen(
                        work: work,
                        localCoverPath: 'assets/icons/app_icon_opaque.png',
                        localWorkDirPath: 'assets/icons',
                        fileTree: [],
                      )
                    : const WorkDetailScreen(work: work),
              ),
            ),
          );
          for (var frame = 0; frame < 6; frame++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          final cover = find.byType(WorkCoverFrame, skipOffstage: false);
          final coverRect = tester.getRect(cover);
          final sourceHero = find.descendant(
            of: cover,
            matching: find.byType(Hero),
          );
          expect(sourceHero, findsOneWidget);
          final artworkRect = tester.getRect(sourceHero);
          expect(tester.widget<Hero>(sourceHero).curve, Curves.easeOutCubic);
          expect(
            tester.widget<Hero>(sourceHero).reverseCurve,
            Curves.easeInCubic,
          );
          final dock = size.width > size.height
              ? find.byType(NavigationRail)
              : find.byType(AppBottomDock);
          final dockRect = tester.getRect(dock);
          final miniPlayerRect = tester.getRect(find.byType(MiniPlayer));
          systemModes.clear();

          await tester.tap(cover);
          for (var frame = 0; frame < 12; frame++) {
            await tester.pump(const Duration(milliseconds: 100));
          }

          expect(navigation.navigationVisible, isTrue);
          expect(tester.getRect(cover), coverRect);
          expect(tester.getRect(dock), dockRect);
          expect(tester.getRect(find.byType(MiniPlayer)), miniPlayerRect);
          expect(dock.hitTestable(), findsNothing);
          final preview = find.byType(CoverPreviewDialog);
          expect(preview, findsOneWidget);
          Future<void> expectDockCovered() async {
            await tester.runAsync(() async {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey('shell-paint')),
              );
              final image = await boundary.toImage();
              try {
                final pixels = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!;
                for (final point in [
                  dockRect.center,
                  Offset(miniPlayerRect.right - 4, miniPlayerRect.center.dy),
                  if (size.width > size.height)
                    Offset(dockRect.right, dockRect.center.dy),
                ]) {
                  final offset =
                      4 * (point.dy.floor() * image.width + point.dx.floor());
                  expect(pixels.getUint32(offset), 0x000000ff);
                }
                final paintedFlight = find.byKey(
                  const ValueKey('player-cover-preview-flight-frame'),
                );
                if (offline && paintedFlight.evaluate().isNotEmpty) {
                  final center = tester.getCenter(paintedFlight);
                  final offset =
                      4 * (center.dy.floor() * image.width + center.dx.floor());
                  expect(pixels.getUint32(offset), isNot(0x000000ff));
                  expect(pixels.getUint8(offset + 3), 255);
                }
              } finally {
                image.dispose();
              }
            });
          }

          await expectDockCovered();
          final route = ModalRoute.of(tester.element(preview))!;
          expect(route, isA<PageRoute<void>>());
          final previewRect = tester.getRect(
            find.byKey(const ValueKey('cover-preview-image-frame')),
          );
          final dismissPoint = Offset(size.width - 8, size.height - 8);
          await tester.tapAt(dismissPoint);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          final flight = find.byKey(
            const ValueKey('player-cover-preview-flight-frame'),
          );
          expect(flight, findsOneWidget);
          final flightRect = tester.getRect(flight);
          expect(flightRect, isNot(artworkRect));
          expect(flightRect, isNot(previewRect));
          expect(tester.getRect(cover), coverRect);
          await expectDockCovered();
          await tester.tapAt(dismissPoint);
          await tester.pump();
          expect(ModalRoute.of(tester.element(cover))!.isCurrent, isTrue);
          final closingFrames =
              (route.reverseTransitionDuration.inMilliseconds / 16).ceil() + 2;
          for (var frame = 0; frame < closingFrames; frame++) {
            expect(tester.getRect(cover), coverRect);
            expect(tester.getRect(dock), dockRect);
            expect(tester.getRect(find.byType(MiniPlayer)), miniPlayerRect);
            await tester.pump(const Duration(milliseconds: 16));
          }

          expect(preview, findsNothing);
          expect(dock.hitTestable(), findsOneWidget);
          for (var frame = 0; frame < 16; frame++) {
            expect(tester.getRect(cover), coverRect);
            expect(tester.getRect(dock), dockRect);
            expect(tester.getRect(find.byType(MiniPlayer)), miniPlayerRect);
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(systemModes, isEmpty);
          expect(tester.takeException(), isNull);
          navigation.navigator!.pop();
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final offline in [false, true]) {
    testWidgets(
      'separate ${offline ? 'offline' : 'online'} detail pages do not share a cover Hero',
      (tester) async {
        const work = Work(id: 42, title: 'Cover preview work');
        final navigation = await _pumpShell(
          tester,
          fakeTagSearch: true,
          offline: offline,
        );
        Widget buildDetail() => offline
            ? const OfflineWorkDetailScreen(
                work: work,
                localCoverPath: 'assets/icons/app_icon_opaque.png',
                localWorkDirPath: 'assets/icons',
                fileTree: [],
              )
            : const WorkDetailScreen(work: work);

        unawaited(
          navigation.navigator!.push(
            MaterialPageRoute<void>(builder: (_) => buildDetail()),
          ),
        );
        for (var frame = 0; frame < 6; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final firstCover = find
            .byType(WorkCoverFrame, skipOffstage: false)
            .first;
        final firstHero = find.descendant(
          of: firstCover,
          matching: find.byType(Hero),
        );
        final firstTag = tester.widget<Hero>(firstHero).tag;

        unawaited(
          navigation.navigator!.push(
            MaterialPageRoute<void>(builder: (_) => buildDetail()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final covers = find.byType(WorkCoverFrame, skipOffstage: false);
        final secondHero = find.descendant(
          of: covers.last,
          matching: find.byType(Hero),
        );
        expect(tester.widget<Hero>(secondHero).tag, isNot(firstTag));
        expect(
          find.byKey(const ValueKey('player-cover-preview-flight-frame')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        if (offline) {
          for (var page = 0; page < 2; page++) {
            navigation.navigator!.pop();
            for (var frame = 0; frame < 6; frame++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final reducedMotion in [false, true]) {
    testWidgets('tab cover preview retains its modal presentation '
        '(reduced motion=$reducedMotion)', (tester) async {
      final bytes = Uint8List.fromList(
        img.encodePng(
          img.fill(
            img.Image(width: 120, height: 120),
            color: img.ColorRgb8(0, 170, 0),
          ),
        ),
      );
      final navigation = await _pumpShell(
        tester,
        size: const Size(1280, 720),
        reducedMotion: reducedMotion,
        homeBuilder: (navigation) => _tabHome(
          navigation,
          Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => GestureDetector(
                  key: const ValueKey('tab-cover-preview-source'),
                  onTap: () => unawaited(
                    CoverPreviewDialog.show(
                      context,
                      imageBytes: bytes,
                      heroTag: 'tab-cover-preview',
                    ),
                  ),
                  child: const PlayerCoverPreviewHero(
                    tag: 'tab-cover-preview',
                    cornerRadius: 12,
                    child: SizedBox(
                      width: 160,
                      height: 120,
                      child: ColoredBox(color: Colors.green),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final source = find.byKey(const ValueKey('tab-cover-preview-source'));
      final sourceRect = tester.getRect(source);
      await tester.runAsync(
        () => precacheImage(MemoryImage(bytes), tester.element(source)),
      );
      await tester.tap(source);
      await tester.pump();
      if (!reducedMotion) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('shell-paint')),
          );
          final image = await (boundary.debugLayer! as OffsetLayer).toImage(
            boundary.paintBounds,
          );
          try {
            final pixels = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            expect(
              pixels.getUint32(4 * (650 * image.width + 640)),
              isNot(0x00aa00ff),
            );
          } finally {
            image.dispose();
          }
        });
        expect(tester.takeException(), isNull);
      }
      await tester.pump(const Duration(milliseconds: 100));
      final preview = find.byType(CoverPreviewDialog);
      final route = ModalRoute.of(tester.element(preview))!;
      final flight = find.byKey(
        const ValueKey('player-cover-preview-flight-frame'),
      );
      expect(route, isA<PageRoute<void>>());
      expect(
        route.barrierLabel,
        MaterialLocalizations.of(
          tester.element(preview),
        ).modalBarrierDismissLabel,
      );
      expect(navigation.rootRouteCoversTabs, isFalse);
      expect(navigation.navigationVisible, isTrue);
      expect(navigation.popupRoute, same(route));
      expect(find.byType(NavigationRail).hitTestable(), findsNothing);
      expect(flight, reducedMotion ? findsNothing : findsOneWidget);
      if (reducedMotion) expect(route.transitionDuration, Duration.zero);
      expect(tester.getRect(source), sourceRect);

      void expectFullWindowBackdrop() {
        final fade = find
            .descendant(of: preview, matching: find.byType(FadeTransition))
            .first;
        expect(tester.getRect(fade), const Rect.fromLTWH(0, 0, 1280, 720));
        final barriers = tester
            .widgetList<ModalBarrier>(find.byType(ModalBarrier))
            .where((barrier) => (barrier.color?.a ?? 0) > 0);
        expect(barriers, isEmpty);
      }

      if (!reducedMotion) expectFullWindowBackdrop();

      Navigator.of(tester.element(preview)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      if (!reducedMotion) {
        expect(navigation.popupRoute, same(route));
        expect(find.byType(NavigationRail).hitTestable(), findsNothing);
        expect(flight, findsOneWidget);
        for (var frame = 0; frame < 4; frame++) {
          expectFullWindowBackdrop();
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      await tester.pumpAndSettle();
      expect(navigation.popupRoute, isNull);
      expect(navigation.rootRouteCoversTabs, isFalse);
      expect(find.byType(NavigationRail).hitTestable(), findsOneWidget);
      expect(tester.getRect(source), sourceRect);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (size, withTrack, fullscreen) in [
    (const Size(390, 844), false, false),
    (const Size(390, 844), true, false),
    (const Size(1280, 720), false, false),
    (const Size(1280, 720), true, false),
    (const Size(390, 844), true, true),
  ]) {
    testWidgets('text preview stays above shared navigation at $size '
        '(track=$withTrack, fullscreen=$fullscreen)', (tester) async {
      final directory = Directory.systemTemp.createTempSync('subtitle_');
      final subtitle = File('${directory.path}/track.srt');
      final content = [
        ...List.generate(100, (index) => 'subtitle line $index'),
        'last subtitle line',
      ].join('\n');
      subtitle.writeAsStringSync(content);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await subtitle.delete();
          await directory.delete();
        });
      });

      final navigation = await _pumpShell(
        tester,
        size: size,
        withTrack: withTrack,
        safePadding: const FakeViewPadding(bottom: 24),
      );
      if (fullscreen) {
        _openPlayer(navigation);
        await tester.pumpAndSettle();
      }
      final navigator = fullscreen
          ? navigation.navigator!
          : navigation.tabNavigator(0)!;
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => TextPreviewScreen(
              textUrl: LocalFileUrl.fromPath(subtitle.path),
              title: 'track.srt',
            ),
          ),
        ),
      );
      await tester.pump();
      for (var attempt = 0; attempt < 40; attempt++) {
        if (find
            .byKey(const ValueKey('text-preview-content'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();

      final preview = find.byType(TextPreviewScreen);
      final scroll = find.descendant(
        of: preview,
        matching: find.byType(SingleChildScrollView),
      );
      final controller = tester
          .widget<SingleChildScrollView>(scroll)
          .controller!;
      final bottom = fullscreen
          ? size.height - 24
          : size.width > size.height
          ? withTrack
                ? tester.getTopLeft(find.byType(MiniPlayer)).dy
                : size.height - 24
          : tester.getTopLeft(find.byType(AppBottomDock)).dy;

      Future<void> expectLastLineVisible(bool editing) async {
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
        final contentFinder = find.byKey(
          ValueKey(
            editing ? 'text-preview-edit-field' : 'text-preview-content',
          ),
        );
        final editable = tester
            .state<EditableTextState>(
              find.descendant(
                of: contentFinder,
                matching: find.byType(EditableText),
              ),
            )
            .renderEditable;
        final lastLine = editable.getLocalRectForCaret(
          TextPosition(offset: content.length),
        );
        expect(tester.getRect(scroll).bottom, closeTo(bottom, 0.01));
        expect(
          editable.localToGlobal(lastLine.bottomLeft).dy,
          lessThanOrEqualTo(bottom),
        );
      }

      await expectLastLineVisible(false);
      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();
      await expectLastLineVisible(true);
      if (fullscreen) expect(find.byType(AppBottomDock), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(390, 600), const Size(1280, 720)]) {
    for (final withTrack in [false, true]) {
      testWidgets(
        'settings stay above shared navigation at $size (track=$withTrack)',
        (tester) async {
          final navigation = await _pumpShell(
            tester,
            size: size,
            withTrack: withTrack,
            safePadding: const FakeViewPadding(bottom: 24),
          );
          unawaited(
            navigation
                .tabNavigator(0)!
                .push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const VideoCardDisplaySettingsScreen(),
                  ),
                ),
          );
          await tester.pumpAndSettle();

          final list = find.byType(ListView);
          final scroll = tester
              .state<ScrollableState>(
                find.descendant(of: list, matching: find.byType(Scrollable)),
              )
              .position;
          scroll.jumpTo(scroll.maxScrollExtent);
          await tester.pumpAndSettle();

          final bottom = size.width > size.height
              ? withTrack
                    ? tester.getTopLeft(find.byType(MiniPlayer)).dy
                    : size.height - 24
              : tester.getTopLeft(find.byType(AppBottomDock)).dy;
          final lastSwitch = find.descendant(
            of: find.byType(SwitchListTile).last,
            matching: find.byType(Switch),
          );
          expect(tester.getRect(list).bottom, closeTo(bottom, 0.01));
          expect(tester.getRect(lastSwitch).bottom, lessThanOrEqualTo(bottom));
          expect(lastSwitch.hitTestable(), findsOneWidget);
          await tester.tap(lastSwitch);
          await tester.pump();
          expect(
            tester
                .widget<SwitchListTile>(find.byType(SwitchListTile).last)
                .value,
            isTrue,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

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

  for (final (size, withTrack, textScale) in [
    (const Size(390, 600), false, 1.0),
    (const Size(390, 600), true, 1.0),
    (const Size(900, 500), true, 1.0),
    (const Size(390, 600), true, 1.6),
  ]) {
    testWidgets('playlist add works stays above Dock at $size '
        '(track=$withTrack, text=$textScale)', (tester) async {
      await _pumpShell(
        tester,
        size: size,
        withTrack: withTrack,
        textScaler: TextScaler.linear(textScale),
        safePadding: const FakeViewPadding(bottom: 24),
      );
      final context = tester.element(
        find.byKey(const ValueKey('home-viewport')),
      );
      final s = S.of(context);
      final dock = size.width > size.height
          ? find.byType(MiniPlayer)
          : find.byType(AppBottomDock);
      final ids = List.generate(24, (i) => 'RJ${123456 + i}');
      List<String>? submitted;
      unawaited(
        PlaylistAddWorksDialog.show(
          context: context,
          onAddWorks: (value) => submitted = value,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), ids.join(' '));
      await tester.pumpAndSettle();
      final action = find.text(s.addNWorks(ids.length));
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(action).bottom,
        lessThanOrEqualTo(size.height - 24),
      );
      expect(action.hitTestable(), findsOneWidget);
      if (size.width < size.height && withTrack) {
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        await tester.pumpAndSettle();
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        expect(tester.getRect(action).bottom, lessThanOrEqualTo(360));
        expect(action.hitTestable(), findsOneWidget);
      }
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(submitted, ids);
      expect(find.byType(PlaylistAddWorksDialog), findsNothing);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(dock.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('subtitle move folder stays above Dock at $size '
        '(track=$withTrack, text=$textScale)', (tester) async {
      await _pumpShell(
        tester,
        size: size,
        withTrack: withTrack,
        textScaler: TextScaler.linear(textScale),
        safePadding: const FakeViewPadding(bottom: 24),
      );
      final context = tester.element(
        find.byKey(const ValueKey('home-viewport')),
      );
      final s = S.of(context);
      final dock = size.width > size.height
          ? find.byType(MiniPlayer)
          : find.byType(AppBottomDock);
      final result = SubtitleLibraryFolderBrowserDialog.show(
        context: context,
        rootPath: '/root',
        folderLoader: (_) async => [],
        pathSeparator: '/',
      );
      await tester.pumpAndSettle();
      final action = find.text(s.rootDirectory);
      expect(
        tester.getRect(action).bottom,
        lessThanOrEqualTo(size.height - 24),
      );
      expect(action.hitTestable(), findsOneWidget);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(await result, '/root');
      expect(find.byType(SubtitleLibraryFolderBrowserDialog), findsNothing);
      expect(dock.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'playlist add works scrolls in a short landscape keyboard viewport',
    (tester) async {
      await _pumpShell(
        tester,
        size: const Size(640, 360),
        textScaler: const TextScaler.linear(2),
      );
      final context = tester.element(
        find.byKey(const ValueKey('home-viewport')),
      );
      final s = S.of(context);
      List<String>? submitted;
      unawaited(
        PlaylistAddWorksDialog.show(
          context: context,
          onAddWorks: (ids) => submitted = ids,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'RJ123456');
      await tester.pumpAndSettle();

      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'RJ123456',
      );
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpAndSettle();
      final action = find.text(s.addNWorks(1));
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      expect(tester.getRect(action).bottom, lessThanOrEqualTo(140));
      expect(action.hitTestable(), findsOneWidget);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(submitted, ['RJ123456']);
      expect(find.byType(PlaylistAddWorksDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('landscape sheet covers Mini Player without resizing the page', (
    tester,
  ) async {
    const size = Size(1280, 720);
    final navigation = await _pumpShell(
      tester,
      size: size,
      safePadding: const FakeViewPadding(left: 44, right: 12, bottom: 20),
    );
    final home = find.byKey(const ValueKey('home-viewport'));
    final initialHomeRect = tester.getRect(home);
    final miniPlayerRect = tester.getRect(find.byType(MiniPlayer));

    final result = showResponsiveBottomSheet<String>(
      context: tester.element(home),
      isDismissible: false,
      builder: (sheetContext) => Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          height: 56,
          child: TextButton(
            onPressed: () => Navigator.of(sheetContext).pop('selected'),
            child: const Text('Select from landscape sheet'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final sheet = find.byKey(const ValueKey('responsive-sheet-surface'));
    expect(tester.getRect(sheet).bottom, closeTo(size.height, 0.1));
    expect(tester.getRect(sheet).overlaps(miniPlayerRect), isTrue);
    expect(tester.getRect(home), initialHomeRect);
    expect(
      find.text('Select from landscape sheet').hitTestable(),
      findsOneWidget,
    );

    await tester.tapAt(
      Offset(miniPlayerRect.left + 20, miniPlayerRect.center.dy),
    );
    await tester.pumpAndSettle();
    expect(find.text('Select from landscape sheet'), findsOneWidget);

    await tester.tap(find.text('Select from landscape sheet'));
    await tester.pumpAndSettle();
    expect(await result, 'selected');
    expect(tester.getRect(home), initialHomeRect);
    expect(find.byType(MiniPlayer).hitTestable(), findsOneWidget);
    expect(navigation.navigationVisible, isTrue);
  });

  testWidgets('landscape sheet keeps a nested dialog above Mini Player', (
    tester,
  ) async {
    await _pumpShell(tester, size: const Size(1280, 720));
    final miniPlayer = tester.getRect(find.byType(MiniPlayer));
    final context = tester.element(find.byKey(const ValueKey('home-viewport')));
    unawaited(
      showResponsiveBottomSheet<void>(
        context: context,
        builder: (sheetContext) => BottomSheetMenu(
          children: [
            ListTile(
              title: const Text('Open landscape dialog'),
              onTap: () => showDialog<void>(
                context: sheetContext,
                builder: (dialogContext) => AlertDialog(
                  content: const Text('Landscape nested dialog'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('Close landscape dialog'),
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
    await tester.tap(find.text('Open landscape dialog'));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byType(AlertDialog)).bottom,
      lessThanOrEqualTo(miniPlayer.top),
    );
    expect(find.text('Close landscape dialog').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Close landscape dialog'));
    await tester.pumpAndSettle();
    expect(find.text('Open landscape dialog').hitTestable(), findsOneWidget);
  });

  for (final size in [const Size(640, 360), const Size(1280, 720)]) {
    for (final rootPage in [false, true]) {
      testWidgets('landscape page FAB clears playback at $size '
          '(root=$rootPage)', (tester) async {
        var taps = 0;
        final page = Scaffold(
          body: const SizedBox.expand(key: ValueKey('ordinary-page-body')),
          floatingActionButton: FloatingActionButton(
            key: const ValueKey('ordinary-page-fab'),
            onPressed: () => taps++,
            child: const Icon(Icons.add),
          ),
        );
        final navigation = await _pumpShell(
          tester,
          size: size,
          homeBuilder: (navigation) => _tabHome(
            navigation,
            rootPage ? const Scaffold(body: Text('Home')) : page,
          ),
        );
        if (rootPage) {
          unawaited(
            navigation.navigator!.push(
              MaterialPageRoute<void>(builder: (_) => page),
            ),
          );
          await tester.pumpAndSettle();
        }
        final fab = find.byKey(const ValueKey('ordinary-page-fab'));
        final mini = tester.getRect(find.byType(MiniPlayer));
        expect(tester.getRect(fab).bottom, lessThanOrEqualTo(mini.top));
        expect(fab.hitTestable(), findsOneWidget);
        await tester.tap(fab);
        await tester.pump();
        expect(taps, 1);

        final body = find.byKey(const ValueKey('ordinary-page-body'));
        final bodyRect = tester.getRect(body);
        unawaited(
          showResponsiveBottomSheet<void>(
            context: tester.element(body),
            builder: (_) => const Text('Full-height sheet'),
          ),
        );
        await tester.pumpAndSettle();
        final panel = tester.getRect(
          find.byKey(const ValueKey('responsive-sheet-surface')),
        );
        expect(panel.bottom, closeTo(size.height, 0.1));
        expect(panel.overlaps(mini), isTrue);
        expect(tester.getRect(body), bodyRect);
      });
    }
  }

  testWidgets('landscape comic download actions scroll above playback', (
    tester,
  ) async {
    final downloads = ComicDownloads(
      _ComicTaskLibrary(),
      (_) => throw UnimplementedError(),
    );
    await downloads.ready;
    downloads.tasks.addAll(
      List.generate(
        12,
        (index) => ComicDownloadTask(
          comic: Comic(source: 'fixture', id: '$index', title: 'Task $index'),
          chapter: const ComicChapter('chapter', 'Chapter'),
          directory: 'unused',
          status: ComicDownloadStatus.complete,
          pages: const [ComicPage('unused')],
          completed: 1,
        ),
      ),
    );
    await _pumpShell(
      tester,
      size: const Size(844, 390),
      homeBuilder: (navigation) => _tabHome(
        navigation,
        ProviderScope(
          overrides: [comicDownloadsProvider.overrideWith((ref) => downloads)],
          child: const ComicDownloadScreen(),
        ),
      ),
    );
    final list = find.descendant(
      of: find.byType(ComicDownloadScreen),
      matching: find.byType(ListView),
    );
    await tester.drag(list, const Offset(0, -6000));
    await tester.pumpAndSettle();
    final lastCard = find.ancestor(
      of: find.text('Task 11'),
      matching: find.byType(Card),
    );
    final delete = find.descendant(
      of: lastCard,
      matching: find.byIcon(Icons.delete_outline),
    );
    expect(
      tester.getRect(delete).bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(MiniPlayer)).top),
    );
    expect(delete.hitTestable(), findsOneWidget);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

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

  for (final withTrack in [false, true]) {
    testWidgets('landscape keyboard resizes the page once (track=$withTrack)', (
      tester,
    ) async {
      await _pumpShell(
        tester,
        size: const Size(844, 390),
        withTrack: withTrack,
      );
      final mini = find.byType(MiniPlayer, skipOffstage: false);
      final miniState = withTrack ? tester.state(mini) : null;
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.byKey(const ValueKey('home-viewport'))).bottom,
        closeTo(390 - 200, 0.01),
      );
      expect(find.byType(MiniPlayer), findsNothing);
      if (withTrack) {
        expect(tester.state(mini), same(miniState));
        expect(mini.hitTestable(), findsNothing);
      }
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(
        find.byType(MiniPlayer),
        withTrack ? findsOneWidget : findsNothing,
      );
      if (withTrack) expect(tester.state(mini), same(miniState));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('landscape keyboard leaves room for the page with large lyrics', (
    tester,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble('player_lyric_miniFontSize', 20);
    await preferences.setDouble('player_lyric_miniLineHeight', 2);
    await _pumpShell(
      tester,
      size: const Size(640, 360),
      textScaler: const TextScaler.linear(2),
      playerStateStream: Stream.value(PlayerState(true, ProcessingState.ready)),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('home-viewport'))).height,
      greaterThan(0),
    );
  });

  testWidgets('landscape sheet stays usable above the keyboard', (
    tester,
  ) async {
    await _pumpShell(tester, size: const Size(844, 390));
    final context = tester.element(find.byKey(const ValueKey('home-viewport')));
    unawaited(
      showResponsiveBottomSheet<void>(
        context: context,
        builder: (_) => const BottomSheetMenu(
          children: [ListTile(title: Text('Landscape sheet action'))],
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    await tester.pumpAndSettle();

    expect(find.text('Landscape sheet action').hitTestable(), findsOneWidget);
    expect(
      tester.getRect(find.text('Landscape sheet action')).bottom,
      lessThanOrEqualTo(190),
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(640, 360), const Size(1280, 720)]) {
    testWidgets(
      'landscape Dock keeps playback beside evenly spaced tabs at $size',
      (tester) async {
        final navigation = await _pumpShell(
          tester,
          size: size,
          safePadding: const FakeViewPadding(left: 44, right: 12, bottom: 20),
        );

        final rail = tester.getRect(find.byType(NavigationRail));
        final mini = tester.getRect(find.byType(MiniPlayer));
        final page = tester.getRect(
          find.byKey(const ValueKey('home-viewport')),
        );
        expect(page.left, closeTo(rail.right + 1, 0.01));
        expect(page.right, closeTo(size.width - 12, 0.01));
        expect(mini.left, closeTo(rail.right + 1, 0.01));
        expect(mini.right, closeTo(size.width - 12, 0.01));
        expect(mini.bottom, closeTo(size.height - 20, 0.01));

        final iconCenters = [
          Icons.library_music,
          Icons.menu_book_outlined,
          Icons.video_library_outlined,
          Icons.settings_outlined,
        ].map((icon) => tester.getCenter(find.byIcon(icon)).dy).toList();
        final gaps = [
          for (var i = 1; i < iconCenters.length; i++)
            iconCenters[i] - iconCenters[i - 1],
        ];
        expect(
          iconCenters.last - iconCenters.first,
          greaterThan(rail.height / 2),
        );
        for (final gap in gaps.skip(1)) {
          expect(gap, closeTo(gaps.first, 24));
        }
        await tester.tap(find.byIcon(Icons.video_library_outlined));
        await tester.pumpAndSettle();
        expect(navigation.selectedIndex, 2);
        expect(find.byIcon(Icons.video_library), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('landscape navigation scrolls when height is limited', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester, size: const Size(640, 240));
    final settings = find.byIcon(Icons.settings_outlined);
    await tester.ensureVisible(settings);
    await tester.pumpAndSettle();
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(navigation.selectedIndex, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape player preserves the navigation scroll position', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester, size: const Size(640, 160));
    final settings = find.byIcon(Icons.settings_outlined);
    final unscrolledTop = tester.getTopLeft(settings).dy;
    await tester.ensureVisible(settings);
    await tester.pumpAndSettle();
    final initialTop = tester.getTopLeft(settings).dy;
    expect(initialTop, lessThan(unscrolledTop));
    _openPlayer(navigation);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getTopLeft(settings).dy, closeTo(initialTop, 0.01));
    await tester.pumpAndSettle();
    navigation.navigator!.pop();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(settings).dy, closeTo(initialTop, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape player keeps offline navigation in place', (
    tester,
  ) async {
    final navigation = await _pumpShell(
      tester,
      size: const Size(1280, 720),
      offline: true,
    );
    final rail = find.byType(NavigationRail);
    final initialRect = tester.getRect(rail);
    final home = find.byKey(
      const ValueKey('home-viewport'),
      skipOffstage: false,
    );
    final initialHomeRect = tester.getRect(home);
    expect(initialRect.top, 0);

    navigation.setPlayerLaunchPreview(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getRect(rail), initialRect);
    expect(tester.getRect(home), initialHomeRect);
    navigation.setPlayerLaunchPreview(false);
    await tester.pumpAndSettle();

    _openPlayer(navigation, child: const ColoredBox(color: Color(0xff13579b)));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getRect(rail), initialRect);
    expect(tester.getRect(home), initialHomeRect);
    final playerTop = tester
        .getTopLeft(find.byKey(const ValueKey('player-viewport')))
        .dy;
    expect(
      tester.getSize(find.byKey(const ValueKey('player-viewport'))),
      const Size(1280, 720),
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
        final offset =
            4 *
            ((playerTop.ceil() + 2) * image.width +
                initialRect.center.dx.floor());
        expect(pixels.getUint32(offset), 0x13579bff);
      } finally {
        image.dispose();
      }
    });
    await tester.pumpAndSettle();
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(rail), initialRect);
    expect(tester.getRect(home), initialHomeRect);
    await tester.pumpAndSettle();
    expect(tester.getRect(rail), initialRect);
    expect(tester.takeException(), isNull);
  });

  for (final withTrack in [false, true]) {
    for (final safePadding in [
      FakeViewPadding.zero,
      const FakeViewPadding(left: 44, right: 12, bottom: 20),
    ]) {
      testWidgets(
        'landscape home stays in place while the player opens and closes '
        '(track=$withTrack, left=${safePadding.left})',
        (tester) async {
          final navigation = await _pumpShell(
            tester,
            size: const Size(1280, 720),
            withTrack: withTrack,
            safePadding: safePadding,
          );
          final home = find.byKey(
            const ValueKey('home-viewport'),
            skipOffstage: false,
          );
          final initialRect = tester.getRect(home);
          final initialElement = tester.element(home);

          _openPlayer(navigation);
          await tester.pump();
          expect(tester.element(home), same(initialElement));
          expect(tester.getRect(home), initialRect, reason: 'first frame');
          await tester.pump(const Duration(milliseconds: 80));
          expect(tester.getRect(home), initialRect, reason: 'player opening');
          expect(
            tester.getSize(find.byKey(const ValueKey('player-viewport'))),
            const Size(1280, 720),
          );
          await tester.pumpAndSettle();

          navigation.navigator!.pop();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          expect(tester.getRect(home), initialRect, reason: 'player closing');
          await tester.pumpAndSettle();
          expect(tester.getRect(home), initialRect, reason: 'player closed');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final startingPlaying in [false, true]) {
    testWidgets(
      'landscape player exit follows playback changes (playing=$startingPlaying)',
      (tester) async {
        final states = StreamController<PlayerState>.broadcast();
        addTearDown(states.close);
        final navigation = await _pumpShell(
          tester,
          size: const Size(1280, 720),
          playerStateStream: states.stream,
        );
        states.add(PlayerState(startingPlaying, ProcessingState.ready));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byType(MiniPlayer)).height,
          startingPlaying ? 88 : 72,
        );

        await tester.tap(
          find.byKey(const ValueKey('mini-player-track-swipe-region')),
        );
        await tester.pumpAndSettle();
        states.add(PlayerState(!startingPlaying, ProcessingState.ready));
        await tester.pumpAndSettle();

        final home = find.byKey(
          const ValueKey('home-viewport'),
          skipOffstage: false,
        );
        navigation.navigator!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        final duringExit = tester.getRect(home);
        await tester.pumpAndSettle();

        expect(tester.getRect(home), duringExit);
        expect(
          tester.getRect(home).bottom,
          closeTo(tester.getRect(find.byType(MiniPlayer)).top, 0.01),
        );
        expect(MediaQuery.paddingOf(tester.element(home)).bottom, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('landscape player exit follows scaled playback height', (
    tester,
  ) async {
    final states = StreamController<PlayerState>.broadcast();
    addTearDown(states.close);
    final navigation = await _pumpShell(
      tester,
      size: const Size(1280, 720),
      textScaler: const TextScaler.linear(2),
      playerStateStream: states.stream,
    );
    states.add(PlayerState(false, ProcessingState.ready));
    await tester.pumpAndSettle();
    _openPlayer(navigation);
    await tester.pumpAndSettle();
    states.add(PlayerState(true, ProcessingState.ready));
    await tester.pumpAndSettle();

    final miniPlayer = find.byType(MiniPlayer, skipOffstage: false);
    final miniPlayerHeight = tester.getSize(miniPlayer).height;
    expect(miniPlayerHeight, greaterThan(88));
    final home = find.byKey(
      const ValueKey('home-viewport'),
      skipOffstage: false,
    );
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final duringExit = tester.getRect(home);
    await tester.pumpAndSettle();

    expect(tester.getRect(home), duringExit);
    expect(tester.getRect(home).bottom, closeTo(720 - miniPlayerHeight, 0.01));
    expect(MediaQuery.paddingOf(tester.element(home)).bottom, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape player exit follows removal of the current track', (
    tester,
  ) async {
    final tracks = StreamController<AudioTrack?>.broadcast();
    addTearDown(tracks.close);
    final navigation = await _pumpShell(
      tester,
      size: const Size(1280, 720),
      trackStream: tracks.stream,
    );
    tracks.add(_track);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('mini-player-track-swipe-region')),
    );
    await tester.pumpAndSettle();
    tracks.add(null);
    await tester.pumpAndSettle();

    final home = find.byKey(
      const ValueKey('home-viewport'),
      skipOffstage: false,
    );
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final duringExit = tester.getRect(home);
    await tester.pumpAndSettle();

    expect(tester.getRect(home), duringExit);
    expect(tester.getRect(home).bottom, 720);
    expect(find.byType(MiniPlayer), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape player can reopen after a drag handoff', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester, size: const Size(1280, 720));
    final launcher = find.byKey(const ValueKey('mini-player-upward-launcher'));
    final gesture = await tester.startGesture(tester.getCenter(launcher));
    for (var step = 0; step < 14; step++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(navigation.audioPlayerRoute, isNotNull);
    expect(find.byType(MiniPlayer), findsNothing);

    navigation.navigator!.pop();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('mini-player-track-swipe-region')),
    );
    await tester.pumpAndSettle();
    expect(navigation.audioPlayerRoute, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape page above the player keeps the full viewport', (
    tester,
  ) async {
    const size = Size(1280, 720);
    final navigation = await _pumpShell(
      tester,
      size: size,
      safePadding: const FakeViewPadding(bottom: 20),
    );
    final home = find.byKey(
      const ValueKey('home-viewport'),
      skipOffstage: false,
    );
    final homeRect = tester.getRect(home);
    _openPlayer(navigation);
    await tester.pumpAndSettle();

    unawaited(
      navigation.navigator!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: SizedBox.expand(key: ValueKey('player-preview-viewport')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(navigation.navigationVisible, isFalse);
    expect(
      tester.getRect(find.byKey(const ValueKey('player-preview-viewport'))),
      Offset.zero & size,
    );
    expect(tester.getRect(home), homeRect);

    final preview = find.byKey(const ValueKey('player-preview-viewport'));
    unawaited(
      showDialog<void>(
        context: tester.element(preview),
        builder: (_) => const AlertDialog(content: Text('Save lyrics')),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(preview), Offset.zero & size);
    navigation.navigator!.pop();
    await tester.pumpAndSettle();

    navigation.navigator!.pop();
    await tester.pumpAndSettle();
    expect(navigation.navigationVisible, isFalse);
    expect(tester.getSize(find.byKey(const ValueKey('player-viewport'))), size);
    navigation.navigator!.pop();
    await tester.pumpAndSettle();
    expect(navigation.navigationVisible, isTrue);
    expect(tester.getRect(home), homeRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape root page stays in place beneath the player', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester, size: const Size(1280, 720));
    unawaited(
      navigation.navigator!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: SizedBox.expand(key: ValueKey('root-page-viewport')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final page = find.byKey(
      const ValueKey('root-page-viewport'),
      skipOffstage: false,
    );
    final initialRect = tester.getRect(page);
    _openPlayer(navigation);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getRect(page), initialRect, reason: 'player opening');
    await tester.pumpAndSettle();
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(page), initialRect, reason: 'player closing');
    await tester.pumpAndSettle();
    expect(tester.getRect(page), initialRect, reason: 'player closed');
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape player preserves the browsing page state', (
    tester,
  ) async {
    final navigation = await _pumpShell(
      tester,
      size: const Size(1280, 720),
      homeBuilder: (navigation) => _StatefulHomeProbe(navigation),
    );
    final home = find.byType(_StatefulHomeProbe, skipOffstage: false);
    final initialState = tester.state(home);
    _openPlayer(navigation);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.state(home), same(initialState));
    await tester.pumpAndSettle();
    navigation.navigator!.pop();
    await tester.pumpAndSettle();
    expect(tester.state(home), same(initialState));
    expect(tester.takeException(), isNull);
  });

  for (final withTrack in [false, true]) {
    for (final safePadding in [
      FakeViewPadding.zero,
      const FakeViewPadding(left: 44, right: 12, bottom: 20),
    ]) {
      for (final offline in [false, true]) {
        testWidgets('landscape player exit preserves the page after rotation '
            '(track=$withTrack, left=${safePadding.left}, offline=$offline)', (
          tester,
        ) async {
          final navigation = await _pumpShell(
            tester,
            withTrack: withTrack,
            safePadding: safePadding,
            offline: offline,
          );
          final home = find.byKey(
            const ValueKey('home-viewport'),
            skipOffstage: false,
          );
          _openPlayer(navigation);
          await tester.pumpAndSettle();
          tester.view.physicalSize = const Size(1280, 720);
          await tester.pumpAndSettle();
          navigation.navigator!.pop();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          final duringExit = tester.getRect(home);
          await tester.pumpAndSettle();
          expect(duringExit, tester.getRect(home));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('landscape player exit follows a changed safe area', (
    tester,
  ) async {
    final navigation = await _pumpShell(
      tester,
      size: const Size(1280, 720),
      safePadding: const FakeViewPadding(left: 44, right: 12, bottom: 20),
    );
    final home = find.byKey(
      const ValueKey('home-viewport'),
      skipOffstage: false,
    );
    _openPlayer(navigation);
    await tester.pumpAndSettle();
    tester.view.padding = const FakeViewPadding(
      left: 12,
      right: 44,
      bottom: 20,
    );
    tester.view.viewPadding = tester.view.padding;
    await tester.pumpAndSettle();
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final duringExit = tester.getRect(home);
    await tester.pumpAndSettle();
    expect(duringExit, tester.getRect(home));
    final rail = tester.getRect(find.byType(NavigationRail));
    expect(duringExit.left, closeTo(rail.right + 1, 0.01));
    expect(duringExit.right, closeTo(1280 - 44, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape player preserves a scrolled browsing page', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final navigation = await _pumpShell(
      tester,
      size: const Size(1280, 720),
      homeBuilder: (navigation) => _tabHome(
        navigation,
        Scaffold(
          body: SingleChildScrollView(
            key: const ValueKey('scrolled-home'),
            controller: scroll,
            child: const SizedBox(height: 2400),
          ),
        ),
      ),
    );
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final home = find.byKey(
      const ValueKey('scrolled-home'),
      skipOffstage: false,
    );
    final initialRect = tester.getRect(home);
    final initialOffset = scroll.offset;

    _openPlayer(navigation);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getRect(home), initialRect);
    expect(scroll.offset, initialOffset);
    await tester.pumpAndSettle();
    expect(scroll.offset, initialOffset);
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(home), initialRect);
    expect(scroll.offset, initialOffset);
    await tester.pumpAndSettle();
    expect(scroll.offset, initialOffset);
    expect(tester.takeException(), isNull);
  });

  for (final target in [
    'mini-player-track-swipe-region',
    'mini-player-queue-button',
  ]) {
    for (final safePadding in [
      FakeViewPadding.zero,
      const FakeViewPadding(left: 44, right: 12, bottom: 20),
    ]) {
      testWidgets(
        'landscape navigation does not flash when tapping the Mini Player '
        '(target=$target, left=${safePadding.left})',
        (tester) async {
          final navigation = await _pumpShell(
            tester,
            size: const Size(1280, 720),
            safePadding: safePadding,
          );
          final railFinder = find.byType(NavigationRail);
          final rail = tester.getRect(railFinder);
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('shell-paint')),
          );
          Future<List<int>> readRail() async =>
              (await tester.runAsync(() async {
                final image = await boundary.toImage();
                try {
                  final pixels = (await image.toByteData(
                    format: ui.ImageByteFormat.rawRgba,
                  ))!;
                  return [
                    for (var y = 0; y < rail.height / 2; y += 3)
                      for (var x = rail.left.toInt(); x < rail.right; x += 3)
                        pixels.getUint32(4 * (y * image.width + x)),
                  ];
                } finally {
                  image.dispose();
                }
              }))!;

          final before = await readRail();
          await tester.tap(find.byKey(ValueKey(target)));
          for (final elapsed in [0, 16, 16, 16]) {
            await tester.pump(Duration(milliseconds: elapsed));
            expect(navigation.audioPlayerRoute, isNotNull);
            expect(
              navigation.audioPlayerNavigationTransition!.value,
              lessThan(0.5),
            );
            final actual = await readRail();
            final changed = [
              for (var i = 0; i < actual.length; i++)
                if (actual[i] != before[i]) i,
            ];
            expect(changed, isEmpty, reason: 'after $elapsed ms');
          }
          await tester.pumpAndSettle();
          navigation.navigator!.pop();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('landscape player covers stationary navigation', (tester) async {
    final navigation = await _pumpShell(
      tester,
      size: const Size(1280, 720),
      safePadding: const FakeViewPadding(left: 44, right: 12, bottom: 20),
    );
    final mini = find.byType(MiniPlayer);
    final rail = find.byType(NavigationRail);
    final initialMiniRect = tester.getRect(mini);
    final initialRailRect = tester.getRect(rail);
    final player = find.byKey(const ValueKey('player-viewport'));
    final route = _openPlayer(
      navigation,
      child: const ColoredBox(color: Color(0xff13579b)),
    );

    Future<void> expectPlayerCoversRail() async {
      final playerTop = tester.getTopLeft(player).dy;
      expect(playerTop, greaterThan(0));
      expect(playerTop, lessThan(720));
      expect(tester.getRect(rail), initialRailRect);
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
          final x = initialRailRect.center.dx;
          expect(pixelAt(x, playerTop / 2), isNot(0x13579bff));
          expect(pixelAt(x, (playerTop + 720) / 2), 0x13579bff);
        } finally {
          image.dispose();
        }
      });
    }

    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getTopLeft(mini).dy, greaterThan(initialMiniRect.top));
    expect(tester.getRect(mini).left, initialMiniRect.left);
    expect(tester.getRect(mini).width, initialMiniRect.width);
    await expectPlayerCoversRail();
    expect(rail.hitTestable(), findsNothing);
    await tester.pumpAndSettle();
    expect(mini, findsNothing);
    expect(rail.hitTestable(), findsNothing);
    expect(
      route.beginVerticalDismissGesture(PlayerDismissVisualMode.main),
      isTrue,
    );
    route.updateVerticalDismissGesture(distance: 240, extent: 720);
    await tester.pump();
    await expectPlayerCoversRail();
    route.updateVerticalDismissGesture(distance: 80, extent: 720);
    await tester.pump();
    await expectPlayerCoversRail();
    route.cancelVerticalDismissGesture();
    await tester.pumpAndSettle();
    var exitCompleted = false;
    unawaited(route.completed.then((_) => exitCompleted = true));
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(exitCompleted, isFalse);
    expect(mini, findsNothing);
    await expectPlayerCoversRail();
    final settings = find.byIcon(Icons.settings_outlined);
    expect(
      tester.getCenter(settings).dy,
      lessThan(tester.getTopLeft(player).dy),
    );
    await tester.tap(settings, warnIfMissed: false);
    expect(navigation.selectedIndex, 0);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(tester.getRect(mini).left, initialMiniRect.left);
    expect(tester.getRect(mini).width, initialMiniRect.width);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(mini).dy, closeTo(initialMiniRect.top, 0.01));
    expect(tester.getRect(rail), initialRailRect);
    expect(rail.hitTestable(), findsOneWidget);
    await tester.tap(settings);
    await tester.pump();
    expect(navigation.selectedIndex, 3);
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
        final railLeft = size.width > size.height
            ? tester.getTopLeft(rail).dx
            : null;

        navigation.setPlayerLaunchPreview(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));

        expect(navigation.navigationVisible, isFalse);
        expect(mini, findsOneWidget);
        expect(tester.state(mini), same(miniState));
        if (size.width > size.height) {
          expect(rail, findsOneWidget);
          expect(tester.getTopLeft(rail).dx, railLeft);
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
        expect(rail, size.width > size.height ? findsOneWidget : findsNothing);
        if (size.width > size.height) {
          expect(mini, findsOneWidget);
          expect(tester.state(mini), same(miniState));
          expect(find.byType(MiniPlayer), findsNothing);
          expect(mini.hitTestable(), findsNothing);
        } else {
          expect(mini, findsNothing);
        }

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

  testWidgets('landscape drag covers and uncovers stationary navigation', (
    tester,
  ) async {
    final navigation = await _pumpShell(tester, size: const Size(1280, 720));
    final rail = find.byType(NavigationRail, skipOffstage: false);
    final railRect = tester.getRect(rail);
    final home = find.byKey(
      const ValueKey('home-viewport'),
      skipOffstage: false,
    );
    final homeRect = tester.getRect(home);
    final launcher = find.byKey(const ValueKey('mini-player-upward-launcher'));

    Future<int> railPixel() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('shell-paint')),
      );
      return (await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          return pixels.getUint32(
            4 * (500 * image.width + railRect.center.dx.floor()),
          );
        } finally {
          image.dispose();
        }
      }))!;
    }

    final initialPixel = await railPixel();
    final gesture = await tester.startGesture(tester.getCenter(launcher));
    await gesture.moveBy(const Offset(0, -300));
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump();
    }
    final player = find.byKey(
      const ValueKey('player-route-vertical-translation'),
      skipOffstage: false,
    );
    expect(tester.getTopLeft(player).dy, lessThan(500));
    expect(tester.getRect(rail), railRect);
    expect(tester.getRect(home), homeRect);
    final coveredPixel = await railPixel();
    expect(coveredPixel, isNot(initialPixel));

    await gesture.moveBy(const Offset(0, 180));
    await tester.pump();
    expect(tester.getTopLeft(player).dy, greaterThan(500));
    expect(tester.getRect(rail), railRect);
    expect(tester.getRect(home), homeRect);
    final uncoveredPixel = await railPixel();
    int colorDistance(int first, int second) => [8, 16, 24]
        .map(
          (shift) =>
              (((first >> shift) & 255) - ((second >> shift) & 255)).abs(),
        )
        .reduce((a, b) => a + b);
    expect(
      colorDistance(uncoveredPixel, initialPixel),
      lessThan(colorDistance(coveredPixel, initialPixel)),
    );
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(navigation.navigationVisible, isTrue);
    expect(tester.getRect(rail), railRect);
    expect(tester.getRect(home), homeRect);
    expect(rail.hitTestable(), findsOneWidget);

    final completedGesture = await tester.startGesture(
      tester.getCenter(launcher),
    );
    await completedGesture.moveBy(const Offset(0, -300));
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump();
    }
    await completedGesture.up();
    await tester.pumpAndSettle();
    expect(navigation.navigationVisible, isFalse);
    expect(tester.getRect(rail), railRect);
    expect(tester.getSize(home), homeRect.size);
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(home), homeRect);
    await tester.pumpAndSettle();
    expect(navigation.navigationVisible, isTrue);
    expect(tester.getRect(rail), railRect);
    expect(tester.getRect(home), homeRect);
    expect(tester.takeException(), isNull);
  });

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
    _openPlayer(navigation);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(NavigationRail, skipOffstage: false), findsNothing);
    await tester.pumpAndSettle();
    navigation.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(NavigationRail, skipOffstage: false), findsNothing);
    await tester.pumpAndSettle();
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
    for (final page in ['cover preview', 'lyric preview']) {
      testWidgets('player keeps its viewport under $page at $size', (
        tester,
      ) async {
        final navigation = await _pumpShell(tester, size: size);
        _openPlayer(navigation);
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
              : find.text('Lyric preview'),
          findsOneWidget,
        );
        expect(find.byType(AppBottomDock), findsNothing);
        expect(find.byType(NavigationRail).hitTestable(), findsNothing);
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

  testWidgets('player metadata search exits without an Audio tab navigator', (
    tester,
  ) async {
    final navigation = await _pumpShell(
      tester,
      fakeTagSearch: true,
      homeBuilder: (_) =>
          const Scaffold(body: SizedBox.expand(key: ValueKey('home-viewport'))),
    );
    expect(navigation.tabNavigator(appAudioTabIndex), isNull);
    final player = _openPlayer(
      navigation,
      child: const Center(
        child: TagChip(tag: Tag(id: 999999, name: 'Test tag')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test tag'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(player.animation!.value, lessThan(1));
    expect(navigation.navigationVisible, isFalse);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-viewport')), findsNothing);
    expect(find.byType(SearchResultScreen), findsOneWidget);
    expect(find.byType(AppBottomDock), findsOneWidget);
    navigation.navigator!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-viewport')), findsOneWidget);
  });

  testWidgets('player metadata search respects reduced motion', (tester) async {
    final navigation = await _pumpShell(
      tester,
      reducedMotion: true,
      fakeTagSearch: true,
      homeBuilder: (navigation) => Navigator(
        key: navigation.tabNavigatorKey(appAudioTabIndex),
        observers: [navigation.tabObserver(appAudioTabIndex)],
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Audio tab')),
        ),
      ),
    );
    final dockRect = tester.getRect(find.byType(AppBottomDock));
    _openPlayer(
      navigation,
      child: const Center(
        child: TagChip(tag: Tag(id: 999999, name: 'Test tag')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test tag'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(SearchResultScreen), findsOneWidget);
    expect(tester.getRect(find.byType(AppBottomDock)), dockRect);
    expect(tester.takeException(), isNull);
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
      if (!pending) await tester.tap(find.text('Test tag'));
      await tester.pumpAndSettle();
      expect(navigation.audioPlayerRoute, isNull);
      expect(navigation.selectedIndex, appAudioTabIndex);
      expect(find.byType(AppBottomDock), findsOneWidget);

      var grid = tester.widget<WorksGridView>(find.byType(WorksGridView));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorksGridView)),
      );
      final api =
          container.read(kikoeruApiServiceProvider) as _EmptyTagSearchApi;
      expect(api.searchCalls, 1);
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
      if (pending) {
        expect(api.blockedToken!.isCancelled, isFalse);
        gate.complete();
      }
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
      expect(api.searchCalls, calls);
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

  testWidgets('reduced motion keeps landscape navigation behind the player', (
    tester,
  ) async {
    final navigation = await _pumpShell(
      tester,
      size: const Size(1280, 720),
      reducedMotion: true,
    );
    final x = tester.getCenter(find.byType(NavigationRail)).dx;
    _openPlayer(navigation, child: const ColoredBox(color: Color(0xff13579b)));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('player-viewport')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('player-viewport'))).dy,
      0,
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
        expect(
          pixels.getUint32(4 * (100 * image.width + x.floor())),
          0x13579bff,
        );
      } finally {
        image.dispose();
      }
    });
    expect(tester.takeException(), isNull);
  });
}

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show PlayerState, ProcessingState;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_details_screen.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_settings_screen.dart';
import 'package:kikoeru_flutter/src/videos/video_download_task.dart';
import 'package:kikoeru_flutter/src/videos/video_downloads.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/videos/video_playback_settings.dart';
import 'package:kikoeru_flutter/src/videos/video_player_platform.dart';
import 'package:kikoeru_flutter/src/videos/video_super_resolution.dart';
import 'package:kikoeru_flutter/src/videos/video_sleep_timer.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';
import 'package:kikoeru_flutter/src/widgets/app_navigation_scope.dart';
import 'package:kikoeru_flutter/src/widgets/app_navigation_shell.dart';
import 'package:kikoeru_flutter/src/widgets/responsive_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_metadata_sections.dart';

import '../support/linux_golden_file_comparator.dart';

final _testPlaybackSessions = <_FakePlaybackSession>[];

void _testPlayerWidget(
  String description,
  Future<void> Function(WidgetTester) body,
) {
  testWidgets(description, (tester) async {
    final initialSessionCount = _testPlaybackSessions.length;
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      for (final session in _testPlaybackSessions.skip(initialSessionCount)) {
        if (session.attached && !session.disposed.isCompleted) {
          await session.disposed.future.timeout(const Duration(seconds: 5));
        }
      }
      await tester.pump();
      _testPlaybackSessions.removeRange(
        initialSessionCount,
        _testPlaybackSessions.length,
      );
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final defaultGoldenFileComparator = goldenFileComparator;
  const videoPlayerChannel = MethodChannel(
    'com.meteor.kikoeruflutter/video_player',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUpAll(() {
    if (Platform.isLinux) {
      goldenFileComparator = LinuxTolerantGoldenFileComparator(
        Uri.parse('test/videos/video_playback_test.dart'),
      );
    }
    messenger.setMockMethodCallHandler(videoPlayerChannel, (call) {
      if (call.method == 'initialize') {
        return SynchronousFuture<Object?>({
          'brightness': false,
          'pictureInPicture': false,
        });
      }
      return SynchronousFuture<Object?>(null);
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) {
      return SynchronousFuture<Object?>(null);
    });
  });
  tearDownAll(() {
    goldenFileComparator = defaultGoldenFileComparator;
    messenger.setMockMethodCallHandler(videoPlayerChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  _testPlayerWidget(
    'iOS offers external subtitles without unsupported shaders',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final session = _FakeAdvancedPlaybackSession();
      await _pumpStandalonePlayer(tester, session);
      await _openSettings(tester);
      final s = await S.delegate.load(const Locale('en'));
      await _ensureMoreMenuItemVisible(tester, find.text(s.loadSubtitle));
      expect(find.text(s.loadSubtitle), findsOneWidget);
      expect(find.text(s.videoPlayerSuperResolution), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget('detail route waits for entry animation to settle', (
    tester,
  ) async {
    final client = _TestMissavClient(_details());
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();
    var sessionCreations = 0;

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        _videoDetailsLauncher(
          sessionFactory: () {
            sessionCreations++;
            return session;
          },
        ),
      ),
    );

    await tester.tap(find.text('Open video'));
    await tester.pump();
    expect(client.detailsCalls, 0);
    expect(sessionCreations, 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(client.detailsCalls, 0);
    expect(sessionCreations, 0);

    for (
      var frame = 0;
      (client.detailsCalls == 0 || session.loadStreamCount == 0) && frame < 40;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(client.detailsCalls, 1);
    expect(sessionCreations, 1);
    expect(session.loadStreamCount, 1);
  });

  for (final supplementFails in [false, true]) {
    for (final covered in [false, true]) {
      _testPlayerWidget(
        'detail preview keeps one player across supplemental result (failure=$supplementFails, covered=$covered)',
        (tester) async {
          final completed = _details(isFavorite: true);
          final preview = VideoDetails(
            video: completed.video,
            sourceId: completed.sourceId,
            streams: completed.streams,
          );
          final client = _TestMissavClient(completed)
            ..readyDetails = preview
            ..detailsCompleter = Completer<VideoDetails>();
          final library = await _testLibrary();
          final downloads = _TestVideoDownloads(
            client: client,
            library: library,
          );
          final session = _FakePlaybackSession();
          var creations = 0;
          await tester.pumpWidget(
            _app(
              client,
              library,
              downloads,
              _testVideoDetailsScreen(
                video: _video(),
                sessionFactory: () {
                  creations++;
                  return session;
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(VideoPlaybackPanel), findsOneWidget);
          expect(session.loadStreamCount, 1);
          expect(creations, 1);
          expect(client.detailsCalls, 1);
          final pendingFavorite = tester.widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.bookmark_outline),
              matching: find.byType(IconButton),
            ),
          );
          expect(pendingFavorite.onPressed, isNull);

          final navigator = Navigator.of(
            tester.element(find.byType(VideoDetailsScreen)),
          );
          if (covered) {
            unawaited(
              navigator.push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Source catalog')),
                ),
              ),
            );
            await tester.pumpAndSettle();
          }
          client.switchAccount(isFavorite: true);
          if (supplementFails) {
            client.detailsCompleter!.completeError(
              const MissavException('Account request failed.'),
            );
          } else {
            client.detailsCompleter!.complete(completed);
          }
          await tester.pumpAndSettle();
          if (covered) {
            navigator.pop();
            await tester.pumpAndSettle();
          }
          expect(find.byType(VideoPlaybackPanel), findsOneWidget);
          expect(session.loadStreamCount, 1);
          expect(creations, 1);
          expect(client.detailsCalls, 1);
          expect(
            find.byIcon(
              supplementFails ? Icons.bookmark_outline : Icons.bookmark,
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (supplementFails) {
            final s = await S.delegate.load(const Locale('en'));
            expect(find.text(s.loadFailed), findsOneWidget);
            expect(find.text(s.retry), findsOneWidget);
          }
        },
      );
    }
  }

  for (final supplementFails in [false, true]) {
    _testPlayerWidget(
      'supplement retry preserves playback and quality (failure=$supplementFails)',
      (tester) async {
        final preview = _details();
        final client = _TestMissavClient(preview)
          ..readyDetails = preview
          ..detailsCompleter = Completer<VideoDetails>()
          ..supplementCompleter = Completer<VideoDetails>();
        final library = await _testLibrary();
        final downloads = _TestVideoDownloads(client: client, library: library);
        final session = _FakePlaybackSession();
        await tester.pumpWidget(
          _app(
            client,
            library,
            downloads,
            _testVideoDetailsScreen(
              video: _video(),
              sessionFactory: () => session,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final s = await S.delegate.load(const Locale('en'));
        await _chooseSetting(tester, '${s.videoQuality}: 720p');
        await _closeSettings(tester);
        await tester.tap(find.byTooltip(s.videoPlay));
        await tester.pump();
        await session.seek(const Duration(seconds: 44));
        final loads = session.loadStreamCount;
        client.detailsCompleter!.completeError(
          const MissavException('Account request failed.'),
        );
        await tester.pumpAndSettle();
        client.detailsCompleter = null;
        client.readyDetails = null;
        client.detailsResult = VideoDetails(
          video: preview.video,
          streams: preview.streams
              .map(
                (stream) => VideoStream(label: stream.label, url: stream.url),
              )
              .toList(),
        );
        await tester.ensureVisible(find.text(s.retry));
        await tester.tap(find.text(s.retry));
        await tester.pumpAndSettle();
        expect(client.detailsCalls, 1);
        expect(client.supplementCalls, 1);
        expect(session.loadStreamCount, loads);
        expect(session.lastStreamUrl, 'https://cdn.example/video-720.m3u8');
        expect(session.snapshot.value.position, const Duration(seconds: 44));
        expect(session.snapshot.value.playing, isTrue);

        if (supplementFails) {
          client.supplementCompleter!.completeError(
            const MissavException('Account request still failed.'),
          );
        } else {
          client.switchAccount(isFavorite: true);
          client.supplementCompleter!.complete(
            VideoDetails(
              video: preview.video,
              sourceId: preview.sourceId,
              streams: preview.streams,
              isFavorite: true,
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(session.loadStreamCount, loads);
        expect(session.lastStreamUrl, 'https://cdn.example/video-720.m3u8');
        expect(session.snapshot.value.position, const Duration(seconds: 44));
        expect(session.snapshot.value.playing, isTrue);
        expect(client.detailsCalls, 1);
        expect(
          find.text(s.loadFailed),
          supplementFails ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  _testPlayerWidget('detail route ignores a late result during pop', (
    tester,
  ) async {
    final client = _TestMissavClient(_details())
      ..detailsCompleter = Completer<VideoDetails>();
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();
    var sessionCreations = 0;

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        _videoDetailsLauncher(
          sessionFactory: () {
            sessionCreations++;
            return session;
          },
        ),
      ),
    );
    await tester.tap(find.text('Open video'));
    await tester.pump();
    await tester.pump();
    final route = ModalRoute.of(
      tester.element(find.byType(VideoDetailsScreen, skipOffstage: false)),
    )!;
    await tester.pump(route.transitionDuration);
    for (
      var frame = 0;
      route.animation!.status != AnimationStatus.completed && frame < 60;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(route.animation!.status, AnimationStatus.completed);
    expect(route.secondaryAnimation?.status, AnimationStatus.dismissed);
    expect(route.navigator!.userGestureInProgressNotifier.value, isFalse);
    for (var frame = 0; client.detailsCalls == 0 && frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      client.detailsCalls,
      1,
      reason:
          'route=${route.animation?.status}, current=${route.isCurrent}, '
          'initializeCalls=${client.initializeCalls}',
    );
    expect(sessionCreations, 0);

    final navigator = Navigator.of(
      tester.element(find.byType(VideoDetailsScreen, skipOffstage: false)),
    );
    navigator.pop();
    await tester.pump();
    client.detailsCompleter!.complete(_details());
    await tester.pump();

    expect(sessionCreations, 0);
    expect(find.byType(VideoPlaybackPanel), findsNothing);
    expect(find.byType(VideoDetailsScreen), findsOneWidget);

    await tester.pumpAndSettle();
    expect(sessionCreations, 0);
    expect(find.byType(VideoPlaybackPanel), findsNothing);
  });

  _testPlayerWidget(
    'detail route pop pauses before completion and retains its surface',
    (tester) async {
      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();

      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _videoDetailsLauncher(sessionFactory: () => session),
        ),
      );
      await tester.tap(find.text('Open video'));
      await tester.pumpAndSettle();
      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoPlay));
      await tester.pump();
      expect(session.snapshot.value.playing, isTrue);

      final detailContext = tester.element(find.byType(VideoDetailsScreen));
      final navigator = Navigator.of(detailContext);
      final route = ModalRoute.of(detailContext)!;
      final playbackLayout = find.byKey(
        const ValueKey('video-playback-layout'),
      );
      var routeCompleted = false;
      unawaited(route.completed.then((_) => routeCompleted = true));

      navigator.userGestureInProgressNotifier.value = true;
      await tester.pump();
      expect(session.pauseCount, 0);
      expect(session.snapshot.value.playing, isTrue);
      navigator.userGestureInProgressNotifier.value = false;
      await tester.pump();
      expect(session.pauseCount, 0);
      expect(session.snapshot.value.playing, isTrue);

      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      expect(session.pauseCount, 0);
      expect(session.snapshot.value.playing, isTrue);
      expect(session.loadStreamCount, 1);
      expect(session.surfaceMountCount, 1);
      expect(session.surfaceDisposeCount, 0);
      expect(ModalRoute.of(tester.element(playbackLayout)), same(route));
      expect(route.isCurrent, isTrue);
      expect(
        find.byKey(const ValueKey('video-fullscreen-placeholder')),
        findsNothing,
      );
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      expect(session.pauseCount, 0);
      expect(session.snapshot.value.playing, isTrue);
      expect(session.loadStreamCount, 1);
      expect(session.surfaceMountCount, 1);
      expect(session.surfaceDisposeCount, 0);
      expect(ModalRoute.of(tester.element(playbackLayout)), same(route));
      expect(route.isCurrent, isTrue);

      navigator.pop();
      await tester.pump();
      expect(session.pauseCount, greaterThan(0));
      expect(session.snapshot.value.playing, isFalse);
      expect(routeCompleted, isFalse);
      expect(session.disposeCount, 0);
      expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);

      await tester.pumpAndSettle();
      expect(routeCompleted, isTrue);
    },
  );

  _testPlayerWidget(
    'shared navigation stays interactive inline and hides only during video fullscreen',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();
      final navigation = AppNavigationController();
      addTearDown(navigation.dispose);
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
          ),
          appNavigationController: navigation,
        ),
      );
      await tester.pumpAndSettle();

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoPlay));
      await tester.pump();
      for (final size in const [Size(400, 800), Size(1200, 800)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        final isLandscape = size.width > size.height;
        final navigationWidget = find.byType(
          isLandscape ? NavigationRail : NavigationBar,
        );
        expect(navigation.navigationVisible, isTrue);
        expect(navigationWidget, findsOneWidget);

        await tester.tap(
          find.descendant(
            of: navigationWidget,
            matching: find.byIcon(Icons.video_library_outlined),
          ),
        );
        await tester.pumpAndSettle();
        expect(navigation.selectedIndex, 2);
        await tester.tap(
          find.descendant(
            of: navigationWidget,
            matching: find.byIcon(Icons.library_music_outlined),
          ),
        );
        await tester.pumpAndSettle();
        expect(navigation.selectedIndex, 0);

        expect(session.snapshot.value.playing, isTrue);
        expect(navigationWidget, findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('video-fullscreen-control')),
        );
        await tester.pumpAndSettle();
        expect(session.snapshot.value.playing, isTrue);
        expect(navigation.navigationVisible, isFalse);
        expect(navigation.selectedIndex, 0);
        expect(navigationWidget, findsNothing);
        expect(
          tester.getRect(find.byKey(const ValueKey('video-playback-layout'))),
          Rect.fromLTWH(0, 0, size.width, size.height),
        );

        await tester.tap(
          find.byKey(const ValueKey('video-fullscreen-control')),
        );
        await tester.pumpAndSettle();
        expect(session.snapshot.value.playing, isTrue);
        expect(navigation.navigationVisible, isTrue);
        expect(navigationWidget, findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget('portrait detail tags scroll above shared navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const genre = VideoLink(
      label: 'Last genre',
      url: 'https://missav.ai/cn/genres/last',
      kind: VideoLinkKind.category,
    );
    final client = _TestMissavClient(
      _details(
        description: List.filled(50, 'Detail line').join('\n'),
        tags: const [genre],
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final navigation = AppNavigationController();
    addTearDown(navigation.dispose);
    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        _testVideoDetailsScreen(
          video: _video(),
          sessionFactory: () => _FakePlaybackSession(),
        ),
        appNavigationController: navigation,
      ),
    );
    await tester.pumpAndSettle();

    final tag = find.text(genre.label);
    await tester.scrollUntilVisible(
      tag,
      500,
      scrollable: find
          .descendant(
            of: find.byKey(
              const PageStorageKey('video-details-portrait-dvd-1'),
            ),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tag.hitTestable(), findsOneWidget);
    expect(
      tester.getBottomLeft(tag).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(NavigationBar)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  _testPlayerWidget(
    'video details keep a centered 40:60 landscape layout and restore its scroll after fullscreen',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const playbackPosition = Duration(seconds: 45);
      final description = List.filled(50, 'Detail line').join('\n');
      final client = _TestMissavClient(_details(description: description));
      final library = await _testLibrary(position: playbackPosition);
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakeAdvancedPlaybackSession();
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();

      const infoKey = PageStorageKey<String>('video-details-landscape-dvd-1');
      final infoPane = find.byKey(infoKey);
      expect(infoPane, findsOneWidget);
      final infoRect = tester.getRect(infoPane);
      expect(infoRect.left, closeTo(480, .1));
      expect(infoRect.right, closeTo(1200, .1));
      final layout = find.byKey(const ValueKey('video-playback-layout'));
      final playerRect = tester.getRect(layout);
      expect(playerRect.left, closeTo(0, .1));
      expect(playerRect.right, closeTo(480, .1));
      expect(playerRect.center.dx, closeTo(240, .1));

      final infoScrollable = find.descendant(
        of: infoPane,
        matching: find.byType(Scrollable),
      );
      final infoPosition = tester
          .state<ScrollableState>(infoScrollable.first)
          .position;
      expect(infoPosition.maxScrollExtent, greaterThan(300));
      infoPosition.jumpTo(300);
      await tester.pumpAndSettle();
      final infoOffset = infoPosition.pixels;
      final playerRectBeforeFullscreen = tester.getRect(layout);

      await session.pause();
      await session.seek(playbackPosition);
      final pauseCount = session.pauseCount;
      final route = ModalRoute.of(tester.element(layout))!;
      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();

      expect(route.isCurrent, isTrue);
      expect(infoPane, findsNothing);
      expect(find.byType(AppBar), findsNothing);
      expect(
        find.byKey(const ValueKey('video-fullscreen-placeholder')),
        findsNothing,
      );
      expect(session.loadStreamCount, 1);
      expect(session.surfaceMountCount, 1);
      expect(session.surfaceDisposeCount, 0);
      expect(session.snapshot.value.playing, isFalse);
      expect(session.snapshot.value.position, playbackPosition);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(route.isCurrent, isTrue);
      expect(infoPane, findsOneWidget);
      expect(tester.getRect(infoPane).left, closeTo(480, .1));
      final restoredScrollable = find.descendant(
        of: infoPane,
        matching: find.byType(Scrollable),
      );
      expect(
        tester.state<ScrollableState>(restoredScrollable.first).position.pixels,
        closeTo(infoOffset, .1),
      );
      expect(tester.getRect(layout), playerRectBeforeFullscreen);
      expect(session.pauseCount, pauseCount);
      expect(session.loadStreamCount, 1);
      expect(session.surfaceMountCount, 1);
      expect(session.surfaceDisposeCount, 0);
      expect(session.snapshot.value.playing, isFalse);
      expect(session.snapshot.value.position, playbackPosition);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'fullscreen exit reveals portrait details on the first portrait frame',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final orientationRestore = Completer<void>();
      var restoreRequested = false;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) {
        if (call.method == 'SystemChrome.setPreferredOrientations' &&
            (call.arguments as List).isEmpty) {
          restoreRequested = true;
          return orientationRestore.future.then<Object?>((_) => null);
        }
        return SynchronousFuture<Object?>(null);
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (_) => SynchronousFuture<Object?>(null),
        );
      });
      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final platform = _TestVideoPlayerPlatform()
        ..windowOrientation = Orientation.portrait;
      final session = _FakePlaybackSession();
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
            platform: platform,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      final layout = find.byKey(const ValueKey('video-playback-layout'));
      expect(
        find.byKey(const PageStorageKey('video-details-portrait-dvd-1')),
        findsNothing,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      for (var frame = 0; !restoreRequested && frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(restoreRequested, isTrue);
      tester.view.physicalSize = const Size(800, 1200);
      await tester.pump();
      final detailsVisibleOnPortraitFrame = find
          .byKey(const PageStorageKey('video-details-portrait-dvd-1'))
          .evaluate()
          .isNotEmpty;
      final playerHeightOnPortraitFrame = tester.getRect(layout).height;
      final detailsRoute = ModalRoute.of(
        tester.element(find.byType(VideoDetailsScreen)),
      )!;
      await tester.binding.handlePopRoute();
      await tester.pump();
      final detailsRouteStayedCurrent = detailsRoute.isCurrent;
      await tester.tap(find.byKey(const ValueKey('video-fullscreen-control')));
      await tester.pump(const Duration(milliseconds: 16));
      final statusBarChangesAfterReentry = List.of(
        platform.fullscreenStatusBarChanges,
      );

      orientationRestore.complete();
      await tester.pumpAndSettle();
      expect(detailsVisibleOnPortraitFrame, isTrue);
      expect(playerHeightOnPortraitFrame, lessThan(800));
      expect(detailsRouteStayedCurrent, isTrue);
      expect(statusBarChangesAfterReentry, [true]);
      expect(session.surfaceMountCount, 1);
      expect(session.surfaceDisposeCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'system back pops a paused detail route after an early fullscreen reveal',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final orientationRestore = Completer<void>();
      var restoreRequested = false;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) {
        if (call.method == 'SystemChrome.setPreferredOrientations' &&
            (call.arguments as List).isEmpty) {
          restoreRequested = true;
          return orientationRestore.future.then<Object?>((_) => null);
        }
        return SynchronousFuture<Object?>(null);
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (_) => SynchronousFuture<Object?>(null),
        );
      });
      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _videoDetailsLauncher(sessionFactory: () => session),
        ),
      );
      await tester.tap(find.text('Open video'));
      await tester.pumpAndSettle();

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      for (var frame = 0; !restoreRequested && frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(restoreRequested, isTrue);
      tester.view.physicalSize = const Size(800, 1200);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const PageStorageKey('video-details-portrait-dvd-1')),
        findsOneWidget,
      );
      expect(session.snapshot.value.playing, isFalse);

      orientationRestore.complete();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Open video'), findsOneWidget);
      expect(find.byType(VideoDetailsScreen), findsNothing);
      expect(session.surfaceDisposeCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'portrait fullscreen waits for the restored landscape before showing details',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final orientationRestore = Completer<void>();
      var restoreRequested = false;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) {
        if (call.method == 'SystemChrome.setPreferredOrientations' &&
            (call.arguments as List).isEmpty) {
          restoreRequested = true;
          return orientationRestore.future.then<Object?>((_) => null);
        }
        return SynchronousFuture<Object?>(null);
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (_) => SynchronousFuture<Object?>(null),
        );
      });
      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final platform = _TestVideoPlayerPlatform()
        ..windowOrientation = Orientation.landscape;
      final session = _FakePlaybackSession();
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
            platform: platform,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      for (var frame = 0; !restoreRequested && frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(restoreRequested, isTrue);
      final portraitDetailsKey = find.byKey(
        const PageStorageKey('video-details-portrait-dvd-1'),
      );
      final portraitDetailsStayedHidden = portraitDetailsKey.evaluate().isEmpty;

      orientationRestore.complete();
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      tester.view.physicalSize = const Size(1200, 800);
      await tester.pump();
      final landscapeDetailsVisibleOnTargetFrame = find
          .byKey(const PageStorageKey('video-details-landscape-dvd-1'))
          .evaluate()
          .isNotEmpty;
      await tester.pumpAndSettle();

      expect(portraitDetailsStayedHidden, isTrue);
      expect(landscapeDetailsVisibleOnTargetFrame, isTrue);
      expect(session.surfaceMountCount, 1);
      expect(session.surfaceDisposeCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final withAudio in [false, true]) {
    _testPlayerWidget(
      'landscape fullscreen entry expands continuously with audio=$withAudio',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        const safeInsets = FakeViewPadding(
          top: 24,
          left: 20,
          right: 20,
          bottom: 16,
        );
        tester.view.padding = safeInsets;
        tester.view.viewPadding = safeInsets;
        addTearDown(tester.view.reset);
        final client = _TestMissavClient(_details());
        final library = await _testLibrary();
        if (withAudio) {
          await StorageService.initCritical(
            preferences: await SharedPreferences.getInstance(),
          );
        }
        final downloads = _TestVideoDownloads(client: client, library: library);
        final platform = _TestVideoPlayerPlatform()
          ..windowOrientation = Orientation.landscape;
        final session = _FakePlaybackSession();
        final navigation = AppNavigationController();
        addTearDown(navigation.dispose);
        await tester.pumpWidget(
          _app(
            client,
            library,
            downloads,
            _testVideoDetailsScreen(
              video: _video(),
              sessionFactory: () => session,
              platform: platform,
            ),
            audioTrack: withAudio
                ? const AudioTrack(
                    id: 'fullscreen-entry-audio',
                    title: 'Audio playing alongside video',
                    url: 'https://example.invalid/audio.mp3',
                  )
                : null,
            appNavigationController: navigation,
          ),
        );
        await tester.pumpAndSettle();

        final layout = find.byKey(const ValueKey('video-playback-layout'));
        final infoPane = find.byKey(
          const PageStorageKey<String>('video-details-landscape-dvd-1'),
        );
        final miniPlayer = find.byKey(
          const ValueKey('mini-player-dismissible'),
        );
        final miniPlayerClip = find
            .ancestor(of: miniPlayer, matching: find.byType(ClipRect))
            .first;
        final inlineRect = tester.getRect(layout);
        final miniPlayerHeight = withAudio
            ? tester.getRect(miniPlayerClip).height
            : 0.0;
        final initialPosition = session.snapshot.value.position;
        final initialPlaying = session.snapshot.value.playing;
        final initialLoads = session.loadStreamCount;
        final l10n = await S.delegate.load(const Locale('en'));
        await tester.tap(find.byTooltip(l10n.videoFullscreen));
        await tester.pump();
        final firstFrameRect = tester.getRect(layout);
        expect((firstFrameRect.left - inlineRect.left).abs(), lessThan(.1));
        expect((firstFrameRect.top - inlineRect.top).abs(), lessThan(.1));
        expect((firstFrameRect.width - inlineRect.width).abs(), lessThan(.1));
        expect((firstFrameRect.height - inlineRect.height).abs(), lessThan(.1));
        expect(navigation.navigationVisible, isFalse);
        expect(find.byType(NavigationRail), findsOneWidget);
        expect(find.byType(NavigationRail).hitTestable(), findsNothing);

        Rect? firstFullscreenFrame;
        var sawIntermediatePlayer = false;
        var sawRetreatingDetails = false;
        var sawIntermediateMiniPlayerHeight = false;
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final rect = tester.getRect(layout);
          if (find.byType(AppBar).evaluate().isEmpty) {
            firstFullscreenFrame ??= rect;
          }
          if (rect.width > inlineRect.width + 1 && rect.width < 1199) {
            sawIntermediatePlayer = true;
            if (infoPane.evaluate().isNotEmpty) {
              final infoLeft = tester.getRect(infoPane).left;
              sawRetreatingDetails |= infoLeft > 480 && infoLeft < 1200;
            }
            if (withAudio) {
              expect(miniPlayer, findsOneWidget);
              final height = tester.getRect(miniPlayerClip).height;
              sawIntermediateMiniPlayerHeight |=
                  height > 0 && height < miniPlayerHeight;
            }
            final stack = find.ancestor(
              of: find.byType(VideoPlaybackPanel),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Stack && widget.clipBehavior == Clip.hardEdge,
              ),
            );
            expect(
              rect.bottom,
              lessThanOrEqualTo(tester.getRect(stack.first).bottom + .1),
            );
          }
        }
        await tester.pumpAndSettle();

        expect(sawIntermediatePlayer, isTrue);
        expect(sawRetreatingDetails, isTrue);
        if (withAudio) expect(sawIntermediateMiniPlayerHeight, isTrue);
        expect(firstFullscreenFrame, isNotNull);
        expect(
          (firstFullscreenFrame!.left - inlineRect.left).abs(),
          lessThan(14),
        );
        expect(
          (firstFullscreenFrame.top - inlineRect.top).abs(),
          lessThan(kToolbarHeight / 4),
        );
        expect(tester.getRect(layout), const Rect.fromLTWH(0, 0, 1200, 800));
        expect(infoPane, findsNothing);
        expect(miniPlayer, findsNothing);
        expect(navigation.navigationVisible, isFalse);
        expect(find.byType(NavigationRail), findsNothing);
        expect(find.byType(AppBar), findsNothing);
        expect(session.surfaceMountCount, 1);
        expect(session.surfaceDisposeCount, 0);
        expect(session.loadStreamCount, initialLoads);
        expect(session.snapshot.value.position, initialPosition);
        expect(session.snapshot.value.playing, initialPlaying);
        expect(tester.takeException(), isNull);
      },
    );
  }

  _testPlayerWidget(
    'landscape fullscreen exit animates the player while the details pane enters',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const genre = VideoLink(
        label: 'Clickable genre',
        url: 'https://missav.ai/cn/genres/clickable-genre',
        kind: VideoLinkKind.category,
      );
      final description = List.filled(50, 'Detail line').join('\n');
      final client = _TestMissavClient(
        _details(description: description, tags: const [genre]),
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final platform = _TestVideoPlayerPlatform()
        ..windowOrientation = Orientation.landscape;
      final session = _FakePlaybackSession();
      final navigation = AppNavigationController();
      addTearDown(navigation.dispose);
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
            platform: platform,
          ),
          appNavigationController: navigation,
        ),
      );
      await tester.pumpAndSettle();

      const infoKey = PageStorageKey<String>('video-details-landscape-dvd-1');
      final infoPane = find.byKey(infoKey);
      final layout = find.byKey(const ValueKey('video-playback-layout'));
      final inlineRect = tester.getRect(layout);
      final inlineInfoLeft = tester.getRect(infoPane).left;
      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      expect(infoPane, findsNothing);
      expect(tester.getRect(layout).width, closeTo(1200, .1));
      final fullscreenPlayerTop = tester.getRect(layout).top;

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      var sawIntermediatePlayerSize = false;
      var sawDetailsBesideShrinkingPlayer = false;
      double? firstDetailsFramePlayerTop;
      for (var frame = 0; frame < 9; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        final playerRect = tester.getRect(layout);
        if (firstDetailsFramePlayerTop == null &&
            infoPane.evaluate().isNotEmpty) {
          firstDetailsFramePlayerTop = playerRect.top;
        }
        if (playerRect.width > 500 && playerRect.width < 1100) {
          sawIntermediatePlayerSize = true;
        }
        if (infoPane.evaluate().isNotEmpty &&
            tester.getRect(infoPane).left < 1200 &&
            playerRect.width > 500) {
          sawDetailsBesideShrinkingPlayer = true;
        }
      }
      await tester.pumpAndSettle();

      expect(sawIntermediatePlayerSize, isTrue);
      expect(sawDetailsBesideShrinkingPlayer, isTrue);
      expect(firstDetailsFramePlayerTop, isNotNull);
      expect(
        (firstDetailsFramePlayerTop! - fullscreenPlayerTop).abs(),
        lessThan(40),
      );
      expect(tester.getRect(layout).width, closeTo(inlineRect.width, .1));
      expect(tester.getRect(infoPane).left, closeTo(inlineInfoLeft, .1));
      expect(session.surfaceMountCount, 1);
      expect(session.surfaceDisposeCount, 0);

      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      for (var frame = 0; frame < 8 && infoPane.evaluate().isEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      tester.view.physicalSize = const Size(800, 1200);
      await tester.pump();
      tester.view.physicalSize = const Size(1200, 800);
      await tester.pumpAndSettle();

      expect(infoPane, findsOneWidget);
      final infoScrollable = find.descendant(
        of: infoPane,
        matching: find.byType(Scrollable),
      );
      final infoPosition = tester
          .state<ScrollableState>(infoScrollable.first)
          .position;
      await tester.drag(infoPane, const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(infoPosition.pixels, greaterThan(0));
      expect(infoPosition.maxScrollExtent, greaterThan(0));
      unawaited(
        infoPosition.animateTo(
          infoPosition.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.ease,
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(genre.label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(genre.label));
      await tester.pumpAndSettle();
      expect(client.browsedUrls, [genre.url]);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'landscape fullscreen exit stays visible while the audio mini player returns',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final downloads = _TestVideoDownloads(client: client, library: library);
      final platform = _TestVideoPlayerPlatform()
        ..windowOrientation = Orientation.landscape;
      final session = _FakePlaybackSession();
      final navigation = AppNavigationController();
      addTearDown(navigation.dispose);
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
            platform: platform,
          ),
          audioTrack: const AudioTrack(
            id: 'fullscreen-audio',
            title: 'Audio playing alongside video',
            url: 'https://example.invalid/audio.mp3',
          ),
          appNavigationController: navigation,
        ),
      );
      await tester.pumpAndSettle();
      final miniPlayer = find.byKey(const ValueKey('mini-player-dismissible'));
      expect(miniPlayer, findsOneWidget);
      final miniPlayerClip = find
          .ancestor(of: miniPlayer, matching: find.byType(ClipRect))
          .first;
      final layout = find.byKey(const ValueKey('video-playback-layout'));
      final inlineRect = tester.getRect(layout);
      final inlineMiniPlayerHeight = tester.getRect(miniPlayerClip).height;
      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      expect(miniPlayer, findsNothing);
      expect(navigation.navigationVisible, isFalse);
      final fullscreenRect = tester.getRect(layout);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.getRect(layout), fullscreenRect);
      var clippedFrames = 0;
      var sawIntermediateMiniPlayerHeight = false;
      for (var frame = 0; frame < 24; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (miniPlayer.evaluate().isNotEmpty) {
          final height = tester.getRect(miniPlayerClip).height;
          sawIntermediateMiniPlayerHeight |=
              height > 0 && height < inlineMiniPlayerHeight;
        }
        final stack = find.ancestor(
          of: find.byType(VideoPlaybackPanel),
          matching: find.byWidgetPredicate(
            (widget) => widget is Stack && widget.clipBehavior == Clip.hardEdge,
          ),
        );
        if (tester.getRect(layout).bottom >
            tester.getRect(stack.first).bottom + .1) {
          clippedFrames++;
        }
      }
      await tester.pumpAndSettle();

      expect(clippedFrames, 0);
      expect(sawIntermediateMiniPlayerHeight, isTrue);
      expect(miniPlayer, findsOneWidget);
      expect(tester.getRect(layout), inlineRect);
      expect(navigation.navigationVisible, isTrue);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(session.surfaceMountCount, 1);
      expect(session.surfaceDisposeCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'landscape fullscreen transitions skip motion when animations are disabled',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final platform = _TestVideoPlayerPlatform()
        ..windowOrientation = Orientation.landscape;
      final session = _FakePlaybackSession();
      final navigation = AppNavigationController();
      addTearDown(navigation.dispose);
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          MediaQuery(
            data: MediaQueryData.fromView(
              tester.view,
            ).copyWith(disableAnimations: true),
            child: _testVideoDetailsScreen(
              video: _video(),
              sessionFactory: () => session,
              platform: platform,
            ),
          ),
          appNavigationController: navigation,
        ),
      );
      await tester.pumpAndSettle();

      final infoPane = find.byKey(
        const PageStorageKey<String>('video-details-landscape-dvd-1'),
      );
      final layout = find.byKey(const ValueKey('video-playback-layout'));
      final l10n = await S.delegate.load(const Locale('en'));
      final inlineRect = tester.getRect(layout);
      final inlineInfoLeft = tester.getRect(infoPane).left;
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      for (
        var frame = 0;
        frame < 10 && find.byType(AppBar).evaluate().isNotEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byType(AppBar), findsNothing);
      expect(navigation.navigationVisible, isFalse);
      expect(tester.getRect(layout).width, closeTo(1200, .1));
      expect(infoPane, findsNothing);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      for (var frame = 0; frame < 10 && infoPane.evaluate().isEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(infoPane, findsOneWidget);
      expect(navigation.navigationVisible, isTrue);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(tester.getRect(layout).width, closeTo(inlineRect.width, .1));
      expect(tester.getRect(infoPane).left, closeTo(inlineInfoLeft, .1));
      expect(session.surfaceMountCount, 1);
      expect(session.surfaceDisposeCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'detail pop during pending quality load prevents resume and retains surface',
    (tester) async {
      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();

      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _videoDetailsLauncher(sessionFactory: () => session),
        ),
      );
      await tester.tap(find.text('Open video'));
      await tester.pump();
      for (
        var frame = 0;
        (client.detailsCalls == 0 || session.loadStreamCount == 0) &&
            frame < 60;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(client.detailsCalls, 1);
      expect(session.loadStreamCount, 1);
      for (
        var frame = 0;
        find
                .byKey(const ValueKey('video-playback-loading'))
                .evaluate()
                .isNotEmpty &&
            frame < 60;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        find.byKey(const ValueKey('video-playback-loading')),
        findsNothing,
      );

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoPlay));
      await tester.pump();
      expect(session.playCount, 1);
      expect(session.snapshot.value.playing, isTrue);

      final loading = Completer<void>();
      session.nextLoadCompleter = loading;
      await _chooseSetting(tester, '${l10n.videoQuality}: 720p');
      expect(session.loadStreamCount, 2);
      expect(session.snapshot.value.playing, isTrue);

      final detailContext = tester.element(find.byType(VideoDetailsScreen));
      final navigator = Navigator.of(detailContext);
      final route = ModalRoute.of(detailContext)!;
      var routeCompleted = false;
      unawaited(route.completed.then((_) => routeCompleted = true));

      navigator.pop();
      await tester.pump();
      await tester.pump();
      expect(session.pauseCount, greaterThan(0));
      expect(session.snapshot.value.playing, isFalse);
      expect(routeCompleted, isFalse);
      expect(session.disposeCount, 0);
      expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);

      loading.complete();
      await tester.pump(const Duration(milliseconds: 16));
      expect(session.playCount, 1);
      expect(session.snapshot.value.playing, isFalse);
      expect(routeCompleted, isFalse);
      expect(session.disposeCount, 0);
      expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);

      await tester.pumpAndSettle();
      expect(routeCompleted, isTrue);
      expect(find.byType(VideoPlaybackPanel), findsNothing);
      await session.disposed.future;
      expect(session.disposeCount, 1);
    },
  );

  _testPlayerWidget('video playback starts paused and keeps its own volume', (
    tester,
  ) async {
    final client = _TestMissavClient(_details());
    final library = await _testLibrary(
      volume: 37,
      position: const Duration(seconds: 12),
    );
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        _testVideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();

    expect(session.loadStreamCount, 1);
    expect(session.lastPosition, const Duration(seconds: 12));
    expect(session.lastVolume, 37);
    expect(session.playCount, 0);
    final l10n = await S.delegate.load(const Locale('en'));
    await _openSettings(tester);
    final volumeSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('video-volume-slider')),
    );
    expect(volumeSlider.value, 37);

    volumeSlider.onChanged!(62);
    volumeSlider.onChangeEnd!(62);
    await tester.pumpAndSettle();
    expect(session.lastVolume, 62);
    expect(library.volume, 62);

    await _closeSettings(tester);
    await _chooseSetting(tester, '${l10n.playbackSpeed}: 1.5×');
    expect(session.lastRate, 1.5);

    await _chooseSetting(tester, '${l10n.videoQuality}: 720p');
    expect(session.loadStreamCount, 2);
    expect(session.lastPosition, const Duration(seconds: 12));

    await tester.tap(find.byTooltip(l10n.videoPlay));
    await tester.pump();
    expect(session.playCount, 1);

    await tester.tap(find.byTooltip(l10n.videoFullscreen));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);
    expect(session.loadStreamCount, 2);
    expect(session.playCount, 1);

    await tester.tap(find.byTooltip(l10n.videoFullscreen));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);
  });

  _testPlayerWidget(
    'paused details player keeps compact controls on its surface',
    (tester) async {
      await _loadPlayerScreenshotFonts();
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();

      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
          ),
          theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
        ),
      );
      await tester.pumpAndSettle();

      final layout = find.byKey(const ValueKey('video-playback-layout'));
      final layoutRect = tester.getRect(layout);
      final controlsRect = tester.getRect(
        find.byKey(const ValueKey('video-controls')),
      );
      final backRect = tester.getRect(
        find.byKey(const ValueKey('video-player-back')),
      );
      final sliderRect = tester.getRect(
        find.byKey(const ValueKey('video-position-slider')),
      );
      expect(session.playCount, 0);
      expect(layoutRect.size, const Size(400, 225));
      expect(controlsRect.top, greaterThanOrEqualTo(layoutRect.top));
      expect(controlsRect.left, greaterThanOrEqualTo(layoutRect.left));
      expect(controlsRect.right, lessThanOrEqualTo(layoutRect.right));
      expect(controlsRect.bottom, lessThanOrEqualTo(layoutRect.bottom));
      expect(controlsRect.height, lessThanOrEqualTo(112));
      expect(backRect.left, layoutRect.left);
      expect(backRect.top, layoutRect.top + 12);
      expect(sliderRect.left, layoutRect.left + 20);
      expect(sliderRect.right, layoutRect.right - 20);
      expect(find.byKey(const ValueKey('video-volume-slider')), findsNothing);

      await expectLater(
        layout,
        matchesGoldenFile('goldens/video_playback_compact_paused.png'),
      );

      expect(
        tester
            .getSize(find.byKey(const ValueKey('video-position-slider')))
            .height,
        50,
      );
      await tester.tapAt(Offset(sliderRect.left + 10, sliderRect.center.dy));
      await tester.pumpAndSettle();
      expect(session.lastPosition, greaterThan(Duration.zero));
      expect(session.lastPosition, lessThan(const Duration(seconds: 10)));
      await tester.tapAt(Offset(sliderRect.right - 10, sliderRect.center.dy));
      await tester.pumpAndSettle();
      expect(session.lastPosition, greaterThan(const Duration(seconds: 170)));
      expect(session.lastPosition, lessThan(const Duration(minutes: 3)));

      tester.view.physicalSize = const Size(1200, 800);
      await tester.pumpAndSettle();
      expect(tester.getSize(layout), const Size(480, 270));
      final expandedSliderRect = tester.getRect(
        find.byKey(const ValueKey('video-position-slider')),
      );
      expect(expandedSliderRect.left, 20);
      expect(expandedSliderRect.right, 460);
      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpAndSettle();

      await _tapGestureSurface(
        tester,
        find.byKey(const ValueKey('video-gesture-surface')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        0,
      );
    },
  );

  _testPlayerWidget('detail more menu uses the space below the inline video', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
    addTearDown(tester.view.reset);
    final client = _TestMissavClient(
      _details(description: List.filled(30, 'Video description').join('\n')),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakeAdvancedPlaybackSession();
    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        _testVideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();
    final layout = find.byKey(const ValueKey('video-playback-layout'));
    await _openSettings(tester);
    final sheet = _responsiveSheet();
    expect(
      tester.getRect(sheet).top,
      closeTo(tester.getRect(layout).bottom, .1),
    );
    expect(
      tester.getSize(sheet).height,
      greaterThan(tester.getSize(layout).height),
    );
    expect(tester.getRect(sheet).bottom, closeTo(800, .1));

    tester.view.physicalSize = const Size(500, 900);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(sheet).top,
      closeTo(tester.getRect(layout).bottom, .1),
    );
    expect(tester.getRect(sheet).bottom, closeTo(900, .1));
    await _closeSettings(tester);
    const detailsListKey = PageStorageKey<String>(
      'video-details-portrait-dvd-1',
    );
    final detailsList = find.byKey(detailsListKey);
    final detailsScrollable = find
        .descendant(of: detailsList, matching: find.byType(Scrollable))
        .first;
    tester.state<ScrollableState>(detailsScrollable).position.jumpTo(20);
    await tester.pumpAndSettle();
    await _openSettings(tester);
    expect(
      tester.getRect(sheet).top,
      closeTo(tester.getRect(layout).bottom, .1),
    );
    expect(tester.takeException(), isNull);
  });

  for (final textScale in [0.8, 2.0]) {
    _testPlayerWidget(
      'more menu fits with tall video at text scale $textScale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(700, 800);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
        addTearDown(tester.view.reset);
        final client = _TestMissavClient(_details());
        final library = await _testLibrary();
        await (await SharedPreferences.getInstance()).setBool(
          'video_player_v1_vertical_expand',
          true,
        );
        final downloads = _TestVideoDownloads(client: client, library: library);
        final session = _FakeAdvancedPlaybackSession(sourceAspectRatio: 9 / 16);
        await tester.pumpWidget(
          _app(
            client,
            library,
            downloads,
            _testVideoDetailsScreen(
              video: _video(),
              sessionFactory: () => session,
            ),
            textScale: textScale,
          ),
        );
        await tester.pumpAndSettle();
        final layout = find.byKey(const ValueKey('video-playback-layout'));
        expect(tester.getRect(layout).bottom, greaterThan(780));
        await _openSettings(tester);
        final sheet = _responsiveSheet();
        expect(tester.getRect(sheet).height, greaterThan(400));
        expect(
          find.descendant(of: sheet, matching: find.text('More')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('video-volume-slider')).hitTestable(),
          findsOneWidget,
        );
        final s = await S.delegate.load(const Locale('en'));
        await _ensureMoreMenuItemVisible(
          tester,
          find.text(s.videoPlayerSettings),
        );
        expect(find.text(s.videoPlayerSettings).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  _testPlayerWidget(
    'more menu stays below inline video and adapts to landscape and fullscreen',
    (tester) async {
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);
      final layout = find.byKey(const ValueKey('video-playback-layout'));
      final l10n = await S.delegate.load(const Locale('en'));

      await _openSettings(tester);
      final sheet = _responsiveSheet();
      final portraitViewportHeight = tester.getSize(layout).height;
      expect(
        tester.getRect(sheet).top,
        closeTo(tester.getRect(layout).bottom, .1),
      );
      expect(tester.getRect(sheet).height, greaterThan(portraitViewportHeight));
      expect(tester.getRect(sheet).bottom, closeTo(800, .1));

      tester.view.physicalSize = const Size(1200, 800);
      await tester.pumpAndSettle();
      final landscapeViewportHeight = tester.getSize(layout).height;
      expect(landscapeViewportHeight, greaterThan(portraitViewportHeight));
      expect(tester.getRect(sheet).height, greaterThan(portraitViewportHeight));
      expect(tester.getRect(sheet).height, lessThanOrEqualTo(800));
      expect(tester.getRect(sheet).right, closeTo(1200, .1));

      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(sheet).top,
        closeTo(tester.getRect(layout).bottom, .1),
      );
      expect(tester.getRect(sheet).bottom, closeTo(800, .1));

      await _closeSettings(tester);
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      expect(tester.getRect(layout).height, 800);
      await _openSettings(tester);
      final fullscreenSheetRect = tester.getRect(sheet);
      expect(fullscreenSheetRect.top, greaterThanOrEqualTo(0));
      expect(fullscreenSheetRect.bottom, closeTo(800, .1));
      expect(fullscreenSheetRect.height, lessThanOrEqualTo(800));
    },
  );

  for (final size in [const Size(400, 800), const Size(1200, 800)]) {
    _testPlayerWidget('more menu keeps its compact header fixed at $size', (
      tester,
    ) async {
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.resetPadding);
      await _pumpStandalonePlayer(
        tester,
        _FakePlaybackSession(),
        width: size.width,
        height: size.height,
      );
      await _openSettings(tester);
      final sheet = _responsiveSheet();
      final header = find.descendant(
        of: sheet,
        matching: find.byType(BottomSheetHeader),
      );
      final initialHeaderRect = tester.getRect(header);
      expect(
        initialHeaderRect.top - tester.getRect(sheet).top,
        closeTo(size.width > size.height ? 24 : 0, .1),
      );
      expect(
        find.descendant(of: header, matching: find.text('More')),
        findsOneWidget,
      );
      final s = await S.delegate.load(const Locale('en'));
      await _ensureMoreMenuItemVisible(
        tester,
        find.text(s.videoPlayerSettings),
      );
      expect(tester.getRect(header), initialHeaderRect);
      expect(find.text(s.videoPlayerSettings).hitTestable(), findsOneWidget);
    });
  }

  _testPlayerWidget('paused and buffering playback controls can be hidden', (
    tester,
  ) async {
    final session = _FakePlaybackSession();
    await _pumpStandalonePlayer(tester, session);
    final surface = find.byKey(const ValueKey('video-gesture-surface'));
    final controls = find.byKey(const ValueKey('video-controls'));
    final l10n = await S.delegate.load(const Locale('en'));

    await _tapGestureSurface(tester, surface);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
    await _tapGestureSurface(tester, surface);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);

    await tester.tap(find.byTooltip(l10n.videoPlay));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);

    session.emitSnapshot(buffering: true);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('video-playback-loading')),
      findsOneWidget,
    );
    expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);

    await _tapGestureSurface(tester, surface);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);
    await _tapGestureSurface(tester, surface);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
  });

  _testPlayerWidget(
    'buffered position is shown on the playback progress rail',
    (tester) async {
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);

      session.emitSnapshot(bufferPosition: const Duration(seconds: 60));
      await tester.pump();

      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('video-position-slider')),
      );
      expect(slider.secondaryTrackValue, 60000);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'fullscreen controls and progress span 20:9 video side bars',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _FakeAdvancedPlaybackSession();
      final platform = _TestVideoPlayerPlatform();
      await _pumpStandalonePlayer(
        tester,
        session,
        width: 1200,
        height: 540,
        platform: platform,
        bounded: true,
      );
      final inlineFrame = find.byKey(const ValueKey('video-playback-layout'));
      expect(tester.getRect(inlineFrame).width, 1200);
      expect(tester.getRect(inlineFrame).height, 540);
      await tester.tap(find.byKey(const ValueKey('video-fullscreen-control')));
      await tester.pumpAndSettle();

      final frame = find.byKey(const ValueKey('video-playback-layout'));
      final frameRect = tester.getRect(frame);
      final videoRect = tester.getRect(
        find.byKey(const ValueKey('fake-video-surface')),
      );
      final backRect = tester.getRect(
        find.byKey(const ValueKey('video-player-back')),
      );
      final moreRect = tester.getRect(
        find.byKey(const ValueKey('video-player-more-menu')),
      );
      final sliderRect = tester.getRect(
        find.byKey(const ValueKey('video-position-slider')),
      );
      expect(frameRect.left, 0);
      expect(frameRect.width, 1200);
      expect(frameRect.height, 540);
      expect(videoRect.width / videoRect.height, closeTo(16 / 9, .001));
      expect(videoRect.left, greaterThan(frameRect.left));
      expect(videoRect.right, lessThan(frameRect.right));
      expect(backRect.left, lessThan(videoRect.left));
      expect(moreRect.right, greaterThan(videoRect.right));
      expect(sliderRect.left, lessThan(videoRect.left));
      expect(sliderRect.right, greaterThan(videoRect.right));

      final gradient = find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).gradient is LinearGradient,
      );
      expect(gradient, findsOneWidget);
      expect(tester.getRect(gradient), frameRect);

      final s = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(s.videoPlayerAspectRatio));
      await tester.pumpAndSettle();
      await tester.tap(find.text(s.videoPlayerFitFourThree));
      await tester.pumpAndSettle();
      final forcedVideoRect = tester.getRect(
        find.byKey(const ValueKey('fake-video-surface')),
      );
      expect(
        forcedVideoRect.width / forcedVideoRect.height,
        closeTo(4 / 3, .001),
      );
      expect(tester.getRect(frame).width, 1200);
      expect(tester.getRect(frame).height, 540);

      await _tapGestureSurface(
        tester,
        find.byKey(const ValueKey('video-gesture-surface')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      final progress = tester.getRect(find.byType(LinearProgressIndicator));
      expect(progress.left, frameRect.left);
      expect(progress.right, frameRect.right);
      expect(progress.bottom, frameRect.bottom);
      expect(platform.fullscreenStatusBarChanges, [true]);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'fullscreen canvas fills the frame while controls avoid cutout and navigation insets',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1000, 600);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(
        left: 40,
        top: 28,
        right: 24,
        bottom: 22,
      );
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      final session = _FakePlaybackSession();
      final platform = _TestVideoPlayerPlatform();
      await _pumpStandalonePlayer(
        tester,
        session,
        width: 1000,
        height: 600,
        platform: platform,
      );
      final s = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byKey(const ValueKey('video-fullscreen-control')));
      await tester.pumpAndSettle();

      expect(platform.fullscreenStatusBarChanges, [true]);
      final layout = find.byKey(const ValueKey('video-playback-layout'));
      final layoutRect = tester.getRect(layout);
      expect(layoutRect.left, 0);
      expect(layoutRect.width, 1000);
      final gradient = find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).gradient is LinearGradient,
      );
      expect(gradient, findsOneWidget);
      expect(tester.getRect(gradient), layoutRect);

      final backRect = tester.getRect(
        find.byKey(const ValueKey('video-player-back')),
      );
      final sliderRect = tester.getRect(
        find.byKey(const ValueKey('video-position-slider')),
      );
      final playRect = tester.getRect(find.byTooltip(s.videoPlay));
      expect(backRect.left, greaterThanOrEqualTo(40));
      expect(backRect.top, greaterThanOrEqualTo(layoutRect.top + 28 + 12));
      expect(sliderRect.left, greaterThanOrEqualTo(60));
      expect(sliderRect.right, lessThanOrEqualTo(956));
      expect(playRect.bottom, lessThanOrEqualTo(layoutRect.bottom - 22 - 12));

      await _tapGestureSurface(
        tester,
        find.byKey(const ValueKey('video-gesture-surface')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.playCount, 0);
      expect(session.snapshot.value.duration, greaterThan(Duration.zero));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        0,
      );
      expect(platform.fullscreenStatusBarChanges, [true]);
      final progress = find.byType(LinearProgressIndicator);
      expect(progress, findsOneWidget);
      final progressRect = tester.getRect(progress);
      expect(progressRect.left, layoutRect.left);
      expect(progressRect.right, layoutRect.right);
      expect(progressRect.bottom, lessThanOrEqualTo(layoutRect.bottom - 22));

      await _tapGestureSurface(
        tester,
        find.byKey(const ValueKey('video-gesture-surface')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byKey(const ValueKey('video-player-more-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(s.videoPlayerLockControls));
      await tester.pumpAndSettle();
      final unlockRect = tester.getRect(
        find.byTooltip(s.videoPlayerUnlockControls),
      );
      expect(unlockRect.left, greaterThanOrEqualTo(40));
      expect(unlockRect.top, greaterThanOrEqualTo(layoutRect.top + 28));
      expect(unlockRect.right, lessThanOrEqualTo(1000 - 24));

      await tester.tap(find.byTooltip(s.videoPlayerUnlockControls));
      await tester.pumpAndSettle();
      expect(platform.fullscreenStatusBarChanges, [true]);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(platform.fullscreenStatusBarChanges, [true, false]);
      expect(
        find.byKey(const ValueKey('video-fullscreen-placeholder')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final exit in [
    'keyboard',
    'button',
    'system back',
    'completion',
    'home',
  ]) {
    _testPlayerWidget(
      'mobile fullscreen stays covered until orientation restore completes: $exit',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final restored = Completer<void>();
        var restoreRequested = false;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) {
          if (call.method == 'SystemChrome.setPreferredOrientations' &&
              (call.arguments as List).isEmpty) {
            restoreRequested = true;
            return restored.future.then<Object?>((_) => null);
          }
          return SynchronousFuture<Object?>(null);
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (_) => SynchronousFuture<Object?>(null),
          );
        });
        final session = _FakePlaybackSession();
        if (exit == 'home') {
          final client = _TestMissavClient(_details());
          final library = await _testLibrary();
          final downloads = _TestVideoDownloads(
            client: client,
            library: library,
          );
          await tester.pumpWidget(
            _app(
              client,
              library,
              downloads,
              Builder(
                builder: (context) => Scaffold(
                  body: Column(
                    children: [
                      const Text('Player test root'),
                      TextButton(
                        onPressed: () => unawaited(
                          pushWorkDetailRoute(
                            context,
                            builder: (_) => _testVideoDetailsScreen(
                              video: _video(),
                              sessionFactory: () => session,
                            ),
                          ),
                        ),
                        child: const Text('Open video'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open video'));
          await tester.pumpAndSettle();
        } else {
          await _pumpStandalonePlayer(tester, session);
        }
        final layout = find.byKey(const ValueKey('video-playback-layout'));
        final fullscreenRoute = ModalRoute.of(tester.element(layout))!;
        await tester.tap(
          find.byKey(const ValueKey('video-fullscreen-control')),
        );
        await tester.pumpAndSettle();
        switch (exit) {
          case 'keyboard':
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          case 'button':
            await tester.tap(
              find.byKey(const ValueKey('video-fullscreen-control')),
            );
          case 'system back':
            await tester.binding.handlePopRoute();
          case 'completion':
            session.complete();
          case 'home':
            await tester.tap(find.byKey(const ValueKey('video-player-home')));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        try {
          expect(restoreRequested, isTrue);
          expect(fullscreenRoute.isCurrent, isTrue);
          expect(layout, findsOneWidget);
          expect(
            find.byKey(const ValueKey('video-fullscreen-placeholder')),
            findsNothing,
          );
        } finally {
          restored.complete();
          await tester.pumpAndSettle();
        }
        if (exit == 'home') {
          expect(find.text('Player test root'), findsOneWidget);
          expect(find.byType(VideoPlaybackPanel), findsNothing);
        } else {
          expect(fullscreenRoute.isCurrent, isTrue);
          expect(layout, findsOneWidget);
        }
      },
    );
  }

  for (final rotates in [true, false]) {
    _testPlayerWidget(
      'fullscreen exit waits for window metrics after platform acknowledgement: rotates=$rotates',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final session = _FakePlaybackSession();
        final platform = _TestVideoPlayerPlatform()
          ..windowOrientation = rotates
              ? Orientation.portrait
              : Orientation.landscape;
        await _pumpStandalonePlayer(
          tester,
          session,
          platform: platform,
          bounded: true,
        );
        await tester.tap(
          find.byKey(const ValueKey('video-fullscreen-control')),
        );
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(800, 400);
        await tester.pump();
        final route = ModalRoute.of(
          tester.element(find.byKey(const ValueKey('video-playback-layout'))),
        )!;

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        if (rotates) {
          expect(route.isCurrent, isTrue);
          expect(
            find.byKey(const ValueKey('video-playback-layout')),
            findsOneWidget,
          );
          await tester.pump(const Duration(seconds: 1));
          expect(route.isCurrent, isTrue);
          tester.view.physicalSize = const Size(400, 800);
          await tester.pumpAndSettle();
        }
        expect(route.isCurrent, isTrue);
        expect(
          find.byKey(const ValueKey('video-playback-layout')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  _testPlayerWidget(
    'disposing while waiting for orientation releases the exit',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final session = _FakePlaybackSession();
      final platform = _TestVideoPlayerPlatform()
        ..windowOrientation = Orientation.portrait;
      await _pumpStandalonePlayer(
        tester,
        session,
        platform: platform,
        bounded: true,
      );
      await tester.tap(find.byKey(const ValueKey('video-fullscreen-control')));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(800, 400);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('video-playback-layout')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(session.disposed.isCompleted, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final pendingStage in ['status bar', 'orientation']) {
    _testPlayerWidget(
      'disposing during fullscreen entry while waiting for $pendingStage restores system state',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final orientationChanges = <List<Object?>>[];
        final orientationReady = Completer<void>();
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            final requested = List<Object?>.from(call.arguments as List);
            orientationChanges.add(requested);
            if (pendingStage == 'orientation' && requested.isNotEmpty) {
              return orientationReady.future.then<Object?>((_) => null);
            }
          }
          return SynchronousFuture<Object?>(null);
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (_) => SynchronousFuture<Object?>(null),
          );
        });
        final statusBarReady = Completer<void>();
        final session = _FakePlaybackSession();
        final platform = _TestVideoPlayerPlatform()
          ..fullscreenStatusBarCompleter = pendingStage == 'status bar'
              ? statusBarReady
              : null;
        await _pumpStandalonePlayer(
          tester,
          session,
          platform: platform,
          bounded: true,
        );

        late final List<bool> barChangesBeforeDispose;
        late final List<List<Object?>> orientationChangesBeforeDispose;
        try {
          await tester.tap(
            find.byKey(const ValueKey('video-fullscreen-control')),
          );
          await tester.pumpAndSettle();
          barChangesBeforeDispose = List<bool>.from(
            platform.fullscreenStatusBarChanges,
          );
          orientationChangesBeforeDispose = [
            for (final changes in orientationChanges)
              List<Object?>.from(changes),
          ];
        } finally {
          try {
            await tester.pumpWidget(const SizedBox.shrink());
          } finally {
            if (pendingStage == 'status bar' && !statusBarReady.isCompleted) {
              statusBarReady.complete();
            }
            if (pendingStage == 'orientation' &&
                !orientationReady.isCompleted) {
              orientationReady.complete();
            }
          }
        }
        await tester.pumpAndSettle();

        expect(barChangesBeforeDispose, [true]);
        if (pendingStage == 'status bar') {
          expect(orientationChangesBeforeDispose, isEmpty);
          expect(orientationChanges, isEmpty);
        } else {
          expect(orientationChangesBeforeDispose, isNotEmpty);
          expect(orientationChangesBeforeDispose.last, isNotEmpty);
          expect(orientationChanges.first, isNotEmpty);
          expect(orientationChanges.last, isEmpty);
        }
        expect(platform.fullscreenStatusBarChanges, [true, false]);
        expect(session.disposed.isCompleted, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  _testPlayerWidget(
    'auto next handles completion received during fullscreen entry',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final library = await _testLibrary();
      await (await SharedPreferences.getInstance()).setInt(
        'video_player_v1_repeat_mode',
        VideoPlayerRepeatMode.related.index,
      );
      final statusBarReady = Completer<void>();
      final platform = _TestVideoPlayerPlatform()
        ..fullscreenStatusBarCompleter = statusBarReady;
      final session = _FakePlaybackSession();
      var nextCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          home: Scaffold(
            body: VideoPlaybackPanel(
              videoId: 'dvd-1',
              library: library,
              streams: _details().streams,
              sessionFactory: () => session,
              platform: platform,
              onPlayNextRelated: () async {
                nextCalls++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('video-fullscreen-control')));
      await tester.pumpAndSettle();
      expect(platform.fullscreenStatusBarChanges, [true]);

      session.complete();
      await tester.pump();
      expect(nextCalls, 0);

      statusBarReady.complete();
      await tester.pumpAndSettle();

      expect(nextCalls, 1);
      expect(platform.fullscreenStatusBarChanges, [true, false]);
      expect(tester.takeException(), isNull);
    },
  );

  for (final exit in ['escape', 'system back']) {
    _testPlayerWidget('fullscreen $exit unlocks controls before exiting', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session, bounded: true);
      final layout = find.byKey(const ValueKey('video-playback-layout'));
      final popScope = find.byType(PopScope<void>);
      final l10n = await S.delegate.load(const Locale('en'));

      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      expect(tester.widget<PopScope<void>>(popScope).canPop, isFalse);
      await _openSettings(tester);
      await tester.tap(find.text(l10n.videoPlayerLockControls));
      await tester.pumpAndSettle();
      expect(find.byTooltip(l10n.videoPlayerUnlockControls), findsOneWidget);

      if (exit == 'escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();

      expect(tester.widget<PopScope<void>>(popScope).canPop, isFalse);
      expect(find.byTooltip(l10n.videoPlayerUnlockControls), findsNothing);
      expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);
      expect(session.surfaceMountCount, 1);
      expect(session.surfaceDisposeCount, 0);

      if (exit == 'escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();

      expect(tester.widget<PopScope<void>>(popScope).canPop, isTrue);
      expect(layout, findsOneWidget);
      expect(session.surfaceMountCount, 1);
      expect(session.surfaceDisposeCount, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final reduceMotion in [false, true]) {
    _testPlayerWidget(
      'audio track expansion animates with reduced motion=$reduceMotion',
      (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(disableAnimations: reduceMotion);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final session = _FakePlaybackSession();
        await _pumpStandalonePlayer(tester, session);
        session.emitSnapshot(
          audioTracks: const [
            VideoPlaybackTrack(id: 'audio-en', label: 'English'),
            VideoPlaybackTrack(id: 'audio-ja', label: 'Japanese'),
          ],
          selectedAudioTrackId: 'audio-en',
        );
        await tester.pump();
        await _openSettings(tester);
        final s = await S.delegate.load(const Locale('en'));
        final entry = find.widgetWithText(ListTile, s.videoPlayerAudioTrack);
        final followingOption = find.widgetWithText(
          SwitchListTile,
          s.videoPlayerRepeatSingle,
        );
        double optionTop() => tester.getTopLeft(followingOption).dy;
        final collapsedTop = optionTop();

        await tester.tap(entry);
        await tester.pump();
        await tester.pump(
          reduceMotion ? Duration.zero : const Duration(milliseconds: 80),
        );
        final expandingTop = optionTop();
        await tester.pumpAndSettle();
        final expandedTop = optionTop();
        expect(expandedTop, greaterThan(collapsedTop));
        if (reduceMotion) {
          expect(expandingTop, closeTo(expandedTop, .1));
        } else {
          expect(expandingTop, greaterThan(collapsedTop));
          expect(expandingTop, lessThan(expandedTop));
        }

        await tester.tap(entry);
        await tester.pump();
        await tester.pump(
          reduceMotion ? Duration.zero : const Duration(milliseconds: 80),
        );
        final collapsingTop = optionTop();
        await tester.pumpAndSettle();
        expect(optionTop(), closeTo(collapsedTop, .1));
        if (reduceMotion) {
          expect(collapsingTop, closeTo(collapsedTop, .1));
        } else {
          expect(collapsingTop, greaterThan(collapsedTop));
          expect(collapsingTop, lessThan(expandedTop));
        }

        await tester.tap(entry);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(optionTop(), closeTo(collapsedTop, .1));
        expect(find.byType(RadioGroup<String>), findsNothing);
        expect(_responsiveSheet(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  _testPlayerWidget(
    'playback settings keep quality, audio, subtitle and rate actions',
    (tester) async {
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);
      session.emitSnapshot(
        audioTracks: const [
          VideoPlaybackTrack(id: 'audio-en', label: 'English'),
          VideoPlaybackTrack(id: 'audio-ja', label: 'Japanese'),
        ],
        selectedAudioTrackId: 'audio-en',
        subtitleTracks: const [
          VideoPlaybackTrack(id: 'subtitle-en', label: 'English'),
        ],
      );
      await tester.pump();
      final l10n = await S.delegate.load(const Locale('en'));

      await _openSettings(tester);
      expect(find.text(l10n.videoPlayerAudioTrack), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.byType(RadioGroup<String>), findsNothing);

      await tester.tap(find.text(l10n.videoPlayerAudioTrack));
      await tester.pumpAndSettle();
      final japaneseOption = find.widgetWithText(
        RadioListTile<String>,
        'Japanese',
      );
      await _ensureMoreMenuItemVisible(tester, japaneseOption);
      expect(
        tester
            .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
            .groupValue,
        'audio-en',
      );
      await tester.tap(japaneseOption);
      await tester.pumpAndSettle();
      expect(session.selectedAudioTrack, 'audio-ja');
      expect(_responsiveSheet(), findsOneWidget);
      expect(find.byType(RadioGroup<String>), findsNothing);

      await _ensureMoreMenuItemVisible(
        tester,
        find.text(l10n.videoPlayerAudioTrack),
      );
      expect(find.text('Japanese'), findsOneWidget);
      await tester.tap(find.text(l10n.videoPlayerAudioTrack));
      await tester.pumpAndSettle();
      await _ensureMoreMenuItemVisible(tester, japaneseOption);
      expect(
        tester
            .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
            .groupValue,
        'audio-ja',
      );
      await _closeSettings(tester);
      await _chooseSetting(
        tester,
        '${l10n.videoPlayerSubtitleTrack}: ${l10n.noSubtitle}',
      );
      expect(session.selectedSubtitleTrack, 'no');
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'video_player_v1_subtitles_enabled',
        ),
        isFalse,
      );
      await _chooseSetting(tester, '${l10n.videoPlayerSubtitleTrack}: English');
      expect(session.selectedSubtitleTrack, 'subtitle-en');
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'video_player_v1_subtitles_enabled',
        ),
        isTrue,
      );
      await _chooseSetting(tester, '${l10n.videoQuality}: 720p');
      expect(session.loadStreamCount, 2);
      await _chooseSetting(tester, '${l10n.playbackSpeed}: 1.25×');
      expect(session.lastRate, 1.25);
      expect(
        (await SharedPreferences.getInstance()).getDouble(
          'video_player_v1_playback_rate',
        ),
        isNull,
      );
      await _chooseSetting(tester, '${l10n.videoQuality}: Auto');
      expect(session.lastRate, 1.25);
    },
  );

  _testPlayerWidget(
    'double tap toggles playback and controls hide and return',
    (tester) async {
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);
      final surface = find.byKey(const ValueKey('video-gesture-surface'));

      await _doubleTap(tester, surface);
      await tester.pumpAndSettle();
      expect(session.playCount, 1);

      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        0,
      );

      final rect = tester.getRect(surface);
      await tester.dragFrom(
        Offset(rect.center.dx, rect.top + 60),
        Offset(rect.width * .1, 0),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        1,
      );
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('video-position-slider')))
            .value,
        9000,
      );

      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        0,
      );

      await _tapGestureSurface(tester, surface);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        1,
      );

      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 200));
      final center = tester.getCenter(surface);
      await tester.sendEventToBinding(PointerHoverEvent(position: center));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        1,
      );

      await _doubleTap(tester, surface);
      await tester.pumpAndSettle();
      expect(session.pauseCount, 1);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        1,
      );
    },
  );

  _testPlayerWidget(
    'player title menu opens settings without pausing playback',
    (tester) async {
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);
      final l10n = await S.delegate.load(const Locale('en'));

      expect(find.text('Fixture video'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('video-player-more-menu')));
      await tester.pumpAndSettle();
      await _ensureMoreMenuItemVisible(
        tester,
        find.text(l10n.videoPlayerSettings),
      );
      await tester.tap(find.text(l10n.videoPlayerSettings));
      await tester.pumpAndSettle();

      final backgroundSetting = find.text(l10n.videoPlayerBackgroundPlayback);
      await tester.scrollUntilVisible(
        backgroundSetting,
        240,
        scrollable: find.byType(Scrollable).last,
      );
      expect(backgroundSetting, findsOneWidget);
      expect(session.pauseCount, 0);
      final backgroundSwitch = find.ancestor(
        of: backgroundSetting,
        matching: find.byType(SwitchListTile),
      );
      expect(tester.widget<SwitchListTile>(backgroundSwitch).value, isFalse);
      await tester.tap(backgroundSetting);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(backgroundSwitch).value, isTrue);
      expect(session.pauseCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'playback more menu opens the sleep timer after it closes',
    (tester) async {
      final timer = VideoSleepTimer.shared;
      timer.cancel();
      addTearDown(timer.cancel);
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);
      final l10n = await S.delegate.load(const Locale('en'));

      await _openSettings(tester);
      final sleepTimerOption = find.text(l10n.videoPlayerSleepTimer);
      await _ensureMoreMenuItemVisible(tester, sleepTimerOption);
      await tester.tap(sleepTimerOption);
      await tester.pumpAndSettle();

      final fifteenMinutes = find.text(l10n.videoPlayerTimerMinutes(15));
      expect(fifteenMinutes, findsOneWidget);
      await tester.tap(fifteenMinutes);
      await tester.pumpAndSettle();
      expect(timer.isActive, isTrue);
      expect(session.pauseCount, 0);

      await tester.tap(find.byTooltip(l10n.close));
      await tester.pumpAndSettle();
      expect(timer.isActive, isTrue);
      expect(tester.takeException(), isNull);
      timer.cancel();
    },
  );

  _testPlayerWidget(
    'system back exits desktop PiP and restores inline playback',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final session = _FakePlaybackSession();
      final platform = _FakeDesktopPiPPlatform();

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          home: Scaffold(
            body: VideoPlaybackPanel(
              videoId: 'dvd-1',
              library: await _testLibrary(),
              streams: _details().streams,
              sessionFactory: () => session,
              platform: platform,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.pictureInPicture.value, isTrue);
      expect(
        find.byTooltip(
          (await S.delegate.load(
            const Locale('en'),
          )).videoPlayerPictureInPicture,
        ),
        findsOneWidget,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(platform.exitCount, 1);
      expect(platform.pictureInPicture.value, isFalse);
      expect(
        find.byKey(const ValueKey('video-playback-layout')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  _testPlayerWidget(
    'desktop PiP restores the fullscreen window state after returning',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final session = _FakePlaybackSession();
      final platform = _FakeDesktopPiPPlatform(initiallyInPip: false);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          home: Scaffold(
            body: VideoPlaybackPanel(
              videoId: 'dvd-1',
              library: await _testLibrary(),
              streams: _details().streams,
              sessionFactory: () => session,
              platform: platform,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);
      expect(platform.nativeFullscreen, isTrue);

      platform.startPictureInPicture();
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey('video-pip-placeholder'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('fake-video-surface'), skipOffstage: false),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);

      await platform.exitPictureInPicture();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('video-pip-placeholder')), findsNothing);
      expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);
      expect(platform.nativeFullscreen, isTrue);
      expect(platform.nativeFullscreenChanges, [true]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(platform.nativeFullscreen, isFalse);
      expect(platform.nativeFullscreenChanges, [true, false]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  _testPlayerWidget('more menu height survives desktop PiP and resize', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final session = _FakeAdvancedPlaybackSession();
    final platform = _FakeDesktopPiPPlatform(initiallyInPip: false);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        home: Scaffold(
          body: ListView(
            children: [
              VideoPlaybackPanel(
                videoId: 'dvd-1',
                library: await _testLibrary(),
                streams: _details().streams,
                sessionFactory: () => session,
                platform: platform,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openSettings(tester);

    final layout = find.byKey(const ValueKey('video-playback-layout'));
    final sheet = _responsiveSheet();
    final portraitViewportHeight = tester.getSize(layout).height;
    expect(
      tester.getRect(sheet).top,
      closeTo(tester.getRect(layout).bottom, .1),
    );

    platform.startPictureInPicture();
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    await platform.exitPictureInPicture();
    await tester.pumpAndSettle();

    final landscapeViewportHeight = tester.getSize(layout).height;
    expect(landscapeViewportHeight, greaterThan(portraitViewportHeight));
    expect(
      find.byKey(const ValueKey('responsive-sheet-surface')),
      findsOneWidget,
    );
    expect(tester.getRect(sheet).height, lessThanOrEqualTo(800));
    expect(tester.getRect(sheet).right, closeTo(1200, .1));
    expect(tester.getRect(sheet).height, greaterThan(portraitViewportHeight));
    expect(tester.takeException(), isNull);
  });

  _testPlayerWidget(
    'Android PiP replaces details with the same video surface',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final session = _FakePlaybackSession();
      final platform = _FakeDesktopPiPPlatform(
        platform: TargetPlatform.android,
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          home: Scaffold(
            appBar: AppBar(title: const Text('Details header')),
            body: ListView(
              children: [
                const Text('Details content'),
                VideoPlaybackPanel(
                  videoId: 'dvd-1',
                  library: await _testLibrary(),
                  streams: _details().streams,
                  sessionFactory: () => session,
                  platform: platform,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Details header'), findsNothing);
      expect(find.text('Details content'), findsNothing);
      expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);
      expect(
        find.byTooltip(
          (await S.delegate.load(
            const Locale('en'),
          )).videoPlayerPictureInPicture,
        ),
        findsNothing,
      );

      await tester.binding.setSurfaceSize(const Size(44, 140));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await platform.exitPictureInPicture();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
      await tester.pumpAndSettle();

      expect(find.text('Details header'), findsOneWidget);
      expect(find.text('Details content'), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  _testPlayerWidget(
    'retry keeps the resume position after a source resets to zero',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final session = _FakePlaybackSession()..resetPositionOnError = true;
      final library = await _testLibrary(position: const Duration(seconds: 60));
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          home: Scaffold(
            body: VideoPlaybackPanel(
              videoId: 'dvd-1',
              library: library,
              streams: _details().streams,
              initialPosition: const Duration(seconds: 60),
              sessionFactory: () => session,
              platform: _TestVideoPlayerPlatform(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(session.snapshot.value.position, const Duration(seconds: 60));

      final l10n = await S.delegate.load(const Locale('en'));
      session.nextLoadError = StateError('Stream changed position');
      await _chooseSetting(tester, '${l10n.videoQuality}: 720p');
      expect(session.requestedPositions.last, const Duration(seconds: 60));
      expect(session.snapshot.value.position, Duration.zero);

      await tester.tap(find.byTooltip(l10n.retry));
      await tester.pumpAndSettle();
      expect(session.requestedPositions.last, const Duration(seconds: 60));
      expect(session.snapshot.value.position, const Duration(seconds: 60));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  _testPlayerWidget(
    'pausing during a delayed stream switch cancels its resume',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);
      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoPlay));
      await tester.pumpAndSettle();

      final load = Completer<void>();
      session.nextLoadCompleter = load;
      await _chooseSetting(tester, '${l10n.videoQuality}: 720p');
      expect(session.loadStreamCount, 2);

      await tester.tap(find.byTooltip(l10n.pause));
      await tester.pump();
      expect(session.snapshot.value.playing, isFalse);
      load.complete();
      await tester.pumpAndSettle();

      expect(session.playCount, 1);
      expect(session.snapshot.value.playing, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  _testPlayerWidget('paused delayed autoplay does not open fullscreen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'video_player_v1_auto_play': true,
      'video_player_v1_auto_fullscreen': true,
    });
    final session = _FakePlaybackSession();
    final load = Completer<void>();
    session.nextLoadCompleter = load;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        home: Scaffold(
          body: VideoPlaybackPanel(
            videoId: 'dvd-1',
            library: await _testLibrary(),
            streams: _details().streams,
            sessionFactory: () => session,
            platform: _TestVideoPlayerPlatform(),
          ),
        ),
      ),
    );
    for (var frame = 0; session.loadStreamCount == 0 && frame < 10; frame++) {
      await tester.pump();
    }
    expect(session.loadStreamCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(session.pauseCount, greaterThan(0));
    load.complete();
    await tester.pumpAndSettle();

    expect(session.playCount, 0);
    expect(
      find.byKey(const ValueKey('video-fullscreen-placeholder')),
      findsNothing,
    );
    expect(
      Navigator.of(
        tester.element(find.byKey(const ValueKey('fake-video-surface'))),
      ).canPop(),
      isFalse,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  _testPlayerWidget(
    'returning to a player applies subtitles changed on another page',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final session = _FakePlaybackSession()
        ..emitSnapshot(
          subtitleTracks: const [
            VideoPlaybackTrack(id: 'en', label: 'English'),
          ],
        );
      final library = await _testLibrary();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          home: Scaffold(
            body: VideoPlaybackPanel(
              videoId: 'dvd-1',
              library: library,
              streams: _details().streams,
              sessionFactory: () => session,
              platform: _TestVideoPlayerPlatform(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(session.selectedSubtitleTrack, 'auto');

      final panelContext = tester.element(find.byType(VideoPlaybackPanel));
      unawaited(
        Navigator.of(panelContext).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const VideoPlaybackSettingsRoute(
              platformFactory: _TestVideoPlayerPlatform.new,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = await S.delegate.load(const Locale('en'));
      final subtitlesSetting = find.ancestor(
        of: find.text(l10n.videoPlayerSubtitleTrack),
        matching: find.byType(SwitchListTile),
      );
      await tester.scrollUntilVisible(
        find.text(l10n.videoPlayerSubtitleTrack),
        240,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(subtitlesSetting);
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'video_player_v1_subtitles_enabled',
        ),
        isFalse,
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(session.selectedSubtitleTrack, 'no');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  _testPlayerWidget(
    'controls stay visible during volume and popup interaction',
    (tester) async {
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);
      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoPlay));
      await tester.pumpAndSettle();

      await _openSettings(tester);
      final volumeSlider = find.byKey(const ValueKey('video-volume-slider'));
      final volumeRect = tester.getRect(volumeSlider);
      final previousVolume = session.lastVolume;
      final volumeGesture = await tester.startGesture(
        Offset(volumeRect.left + volumeRect.width * .75, volumeRect.center.dy),
        kind: PointerDeviceKind.touch,
      );
      await volumeGesture.moveBy(Offset(-volumeRect.width * .1, 0));
      await tester.pump();
      expect(session.lastVolume, isNot(previousVolume));
      expect(tester.widget<Slider>(volumeSlider).value, isNot(previousVolume));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        1,
      );

      await volumeGesture.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        1,
      );

      final surfaceRect = tester.getRect(
        find.byKey(const ValueKey('video-gesture-surface')),
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        0,
      );
      await tester.tapAt(Offset(surfaceRect.center.dx, surfaceRect.top + 60));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      await _openSettings(tester);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        1,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        0,
      );
    },
  );

  _testPlayerWidget(
    'surface and slider seek once on release and clamp to duration',
    (tester) async {
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);
      final surface = find.byKey(const ValueKey('video-gesture-surface'));
      final rect = tester.getRect(surface);

      await tester.dragFrom(
        Offset(rect.left + rect.width * .1, rect.top + 60),
        Offset(rect.width * .1, 0),
      );
      await tester.pump();
      expect(session.seekCount, 1);
      expect(session.lastPosition, const Duration(seconds: 9));

      await tester.dragFrom(
        Offset(rect.left + rect.width * .7, rect.top + 60),
        Offset(rect.width * .1, 0),
      );
      await tester.pump();
      expect(session.seekCount, 2);
      expect(session.lastPosition, const Duration(seconds: 18));

      await tester.dragFrom(
        Offset(rect.left + rect.width * .5, rect.top + 60),
        Offset(rect.width * 2, 0),
      );
      await tester.pump();
      expect(session.seekCount, 3);
      expect(session.lastPosition, const Duration(minutes: 3));

      final cancelled = await tester.startGesture(
        Offset(rect.left + rect.width * .4, rect.top + 60),
        kind: PointerDeviceKind.touch,
      );
      await cancelled.moveTo(
        Offset(rect.left + rect.width * .6, rect.top + 60),
      );
      await cancelled.cancel();
      await tester.pump();
      expect(session.seekCount, 3);

      final sliderFinder = find.byKey(const ValueKey('video-position-slider'));
      final sliderRect = tester.getRect(sliderFinder);
      final cancelledSlider = await tester.startGesture(
        Offset(sliderRect.left + sliderRect.width * .25, sliderRect.center.dy),
        kind: PointerDeviceKind.touch,
      );
      await cancelledSlider.moveTo(
        Offset(sliderRect.left + sliderRect.width * .75, sliderRect.center.dy),
      );
      await tester.pump();
      await cancelledSlider.cancel();
      await tester.pump();
      expect(session.seekCount, 3);
      expect(session.lastPosition, const Duration(minutes: 3));

      var slider = tester.widget<Slider>(sliderFinder);
      slider.onChanged!(123000);
      await tester.pump();
      expect(session.seekCount, 3);
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('video-position-slider')))
            .value,
        123000,
      );

      slider = tester.widget<Slider>(
        find.byKey(const ValueKey('video-position-slider')),
      );
      slider.onChangeEnd!(123000);
      await tester.pump();
      expect(session.seekCount, 4);
      expect(session.lastPosition, const Duration(seconds: 123));
      await tester.pump(const Duration(milliseconds: 400));
    },
  );

  _testPlayerWidget(
    'long press restores the selected rate after cancel and background',
    (tester) async {
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);
      final l10n = await S.delegate.load(const Locale('en'));

      await tester.tap(find.byTooltip(l10n.videoPlay));
      await tester.pumpAndSettle();
      await _chooseSetting(tester, '${l10n.playbackSpeed}: 1.5×');
      expect(session.lastRate, 1.5);

      final surface = find.byKey(const ValueKey('video-gesture-surface'));
      final surfaceRect = tester.getRect(surface);
      final center = Offset(
        surfaceRect.center.dx,
        surfaceRect.top + surfaceRect.height * .25,
      );
      final delayedRate = Completer<void>();
      session.nextRateCompleter = delayedRate;
      final cancelled = await tester.startGesture(
        center,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(session.rateChanges, [1.5]);
      await cancelled.cancel();
      await tester.pump();
      delayedRate.complete();
      await tester.pumpAndSettle();
      expect(session.rateChanges, [1.5, 3, 1.5]);
      expect(session.lastRate, 1.5);

      final backgrounded = await tester.startGesture(
        center,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(session.lastRate, 3);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(session.lastRate, 1.5);
      await backgrounded.cancel();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      await tester.tap(find.byTooltip(l10n.videoPlay));
      await tester.pumpAndSettle();
      final fullscreenDuringLongPress = await tester.startGesture(
        center,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(session.lastRate, 3);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      final videoSurface = find.byKey(const ValueKey('fake-video-surface'));
      expect(Navigator.of(tester.element(videoSurface)).canPop(), isFalse);

      await fullscreenDuringLongPress.up();
      await tester.pumpAndSettle();
      expect(session.lastRate, 1.5);
      expect(session.snapshot.value.playing, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(Navigator.of(tester.element(videoSurface)).canPop(), isFalse);
    },
  );

  for (final viewCase in [
    (fullscreen: false, bottomInset: 0.0),
    (fullscreen: true, bottomInset: 24.0),
    (fullscreen: true, bottomInset: 34.0),
  ]) {
    _testPlayerWidget(
      'two-finger pinch zoom can be restored to the original view '
      '(fullscreen=${viewCase.fullscreen}, bottomInset=${viewCase.bottomInset})',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.padding = FakeViewPadding(bottom: viewCase.bottomInset);
        addTearDown(tester.view.resetPadding);
        final session = _FakePlaybackSession();
        await _pumpStandalonePlayer(
          tester,
          session,
          width: viewCase.fullscreen ? 1000 : 400,
          height: viewCase.fullscreen ? 600 : 800,
        );
        if (viewCase.fullscreen) {
          await tester.tap(
            find.byKey(const ValueKey('video-fullscreen-control')),
          );
          await tester.pumpAndSettle();
        }
        final videoSurface = find.byKey(const ValueKey('fake-video-surface'));
        final rect = tester.getRect(videoSurface);
        final first = await tester.startGesture(
          Offset(rect.left + rect.width * .35, rect.center.dy),
          pointer: 41,
          kind: PointerDeviceKind.touch,
        );
        final second = await tester.startGesture(
          Offset(rect.left + rect.width * .65, rect.center.dy),
          pointer: 42,
          kind: PointerDeviceKind.touch,
        );
        await first.moveBy(Offset(-rect.width * .15, 0));
        await second.moveBy(Offset(rect.width * .15, 0));
        await tester.pump();
        expect(
          tester
              .widget<Transform>(
                find.byKey(const ValueKey('video-surface-transform')),
              )
              .transform
              .getMaxScaleOnAxis(),
          greaterThan(1),
        );

        await first.up();
        await second.up();
        await tester.pump();
        final positionBeforeRestore = session.lastPosition;
        await tester.tap(find.byKey(const ValueKey('video-restore-screen')));
        await tester.pump();
        expect(
          tester
              .widget<Transform>(
                find.byKey(const ValueKey('video-surface-transform')),
              )
              .transform
              .getMaxScaleOnAxis(),
          1,
        );
        expect(session.lastPosition, positionBeforeRestore);
        expect(tester.takeException(), isNull);
      },
    );
  }

  _testPlayerWidget(
    'focused keyboard controls seek and preserve one fullscreen surface',
    (tester) async {
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session, width: 320);
      expect(tester.takeException(), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(session.playCount, 0);

      final surface = find.byKey(const ValueKey('video-gesture-surface'));
      final videoSurface = find.byKey(const ValueKey('fake-video-surface'));
      final surfaceRect = tester.getRect(surface);
      expect(Navigator.of(tester.element(videoSurface)).canPop(), isFalse);
      await tester.tapAt(Offset(surfaceRect.center.dx, surfaceRect.top + 10));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(session.playCount, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(session.seekCount, 1);
      expect(session.lastPosition, const Duration(seconds: 10));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(session.lastVolume, 90);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(session.lastVolume, 100);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 199));
      expect(session.lastRate, 1);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(session.lastRate, 3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(session.lastRate, 1);
      expect(session.seekCount, 1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(session.lastRate, 2);

      final keyFHandled = await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(keyFHandled, isTrue);
      expect(
        find.byKey(const ValueKey('video-fullscreen-placeholder')),
        findsNothing,
      );
      expect(videoSurface, findsOneWidget);
      expect(Navigator.of(tester.element(videoSurface)).canPop(), isFalse);
      expect(tester.takeException(), isNull);
      final playerFocus = tester
          .widget<Focus>(find.byKey(const ValueKey('video-player-focus')))
          .focusNode!;
      expect(playerFocus.hasFocus, isTrue);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('video-controls')),
            )
            .opacity,
        0,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('video-fullscreen-placeholder')),
        findsNothing,
      );
      expect(videoSurface, findsOneWidget);
      expect(Navigator.of(tester.element(videoSurface)).canPop(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'fullscreen control uses native fullscreen on primary and app fullscreen on secondary tap',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues({});
      final session = _FakePlaybackSession();
      final platform = _FakeDesktopPiPPlatform(initiallyInPip: false);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          home: Scaffold(
            body: VideoPlaybackPanel(
              videoId: 'dvd-1',
              library: await _testLibrary(),
              streams: _details().streams,
              sessionFactory: () => session,
              platform: platform,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fullscreenControl = find.byKey(
        const ValueKey('video-fullscreen-control'),
      );
      await tester.tap(fullscreenControl);
      await tester.pumpAndSettle();
      expect(platform.nativeFullscreenChanges, [true]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(platform.nativeFullscreenChanges, [true, false]);

      await tester.tapAt(
        tester.getCenter(fullscreenControl),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(platform.nativeFullscreenChanges, [true, false]);
      expect(Navigator.of(tester.element(fullscreenControl)).canPop(), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(platform.nativeFullscreenChanges, [true, false]);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'repeated fullscreen entry waits for one native transition',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final session = _FakePlaybackSession();
      final transition = Completer<void>();
      final platform = _FakeDesktopPiPPlatform(initiallyInPip: false)
        ..nextFullscreenCompleter = transition;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          home: Scaffold(
            body: VideoPlaybackPanel(
              videoId: 'dvd-1',
              library: await _testLibrary(),
              streams: _details().streams,
              sessionFactory: () => session,
              platform: platform,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final control = find.byKey(const ValueKey('video-fullscreen-control'));
      await tester.tap(control);
      await tester.pump();
      await tester.tap(control);
      await tester.pump();
      transition.complete();
      await tester.pumpAndSettle();

      expect(platform.nativeFullscreenChanges, [true]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      final surface = find.byKey(const ValueKey('fake-video-surface'));
      expect(surface, findsOneWidget);
      expect(Navigator.of(tester.element(surface)).canPop(), isFalse);
      expect(platform.nativeFullscreenChanges, [true, false]);
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'fit modes preserve the source ratio until a ratio is forced',
    (tester) async {
      final session = _FakeAdvancedPlaybackSession(sourceAspectRatio: 4 / 3);
      await _pumpStandalonePlayer(tester, session, width: 600);
      final s = await S.delegate.load(const Locale('en'));
      final surface = find.byKey(const ValueKey('fake-video-surface'));
      final viewport = find.byKey(const ValueKey('video-playback-layout'));
      Rect surfaceBounds() => Rect.fromPoints(
        tester.getTopLeft(surface),
        tester.getBottomRight(surface),
      );

      expect(
        surfaceBounds().width / surfaceBounds().height,
        closeTo(4 / 3, .001),
      );
      expect(surfaceBounds().width, lessThan(tester.getSize(viewport).width));
      for (final (label, ratio) in [
        (s.videoPlayerFitCover, 4 / 3),
        (s.videoPlayerFitWidth, 4 / 3),
        (s.videoPlayerFitHeight, 4 / 3),
        (s.videoPlayerFitFourThree, 4 / 3),
        (s.videoPlayerFitSixteenNine, 16 / 9),
        (s.videoPlayerFitContain, 4 / 3),
      ]) {
        await tester.tap(find.byTooltip(s.videoPlayerAspectRatio));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        final bounds = surfaceBounds();
        expect(
          bounds.width / bounds.height,
          closeTo(ratio, .001),
          reason: label,
        );
        if (label == s.videoPlayerFitCover) {
          expect(bounds.height, greaterThan(tester.getSize(viewport).height));
        }
      }
    },
  );

  _testPlayerWidget(
    'fullscreen volume control updates while playback is paused',
    (tester) async {
      final client = _TestMissavClient(_details());
      final library = await _testLibrary(volume: 37);
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();

      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(session.playCount, 0);

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      await _openSettings(tester);
      final volumeSlider = tester.widget<Slider>(
        find.byKey(const ValueKey('video-volume-slider')),
      );
      volumeSlider.onChanged!(68);
      volumeSlider.onChangeEnd!(68);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('video-volume-slider')))
            .value,
        68,
      );
      expect(session.lastVolume, 68);
      expect(library.volume, 68);
      expect(session.playCount, 0);
    },
  );

  _testPlayerWidget(
    'fullscreen quality loading and errors remain visible paused',
    (tester) async {
      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();

      final loading = Completer<void>();
      session.nextLoadCompleter = loading;
      await _chooseSetting(tester, '${l10n.videoQuality}: 720p');
      expect(session.loadStreamCount, 2);
      expect(session.lastStreamUrl, 'https://cdn.example/video-720.m3u8');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('video-playback-loading')),
        findsOneWidget,
      );
      loading.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('video-playback-loading')),
        findsNothing,
      );

      session.nextLoadError = StateError('Fixture stream error');
      await _chooseSetting(tester, '${l10n.videoQuality}: Auto');
      expect(find.text(l10n.videoPlaybackFailed), findsOneWidget);
      expect(
        find.byKey(const ValueKey('video-playback-loading')),
        findsNothing,
      );
      expect(session.playCount, 0);
    },
  );

  _testPlayerWidget('player errors replace loading while an open is pending', (
    tester,
  ) async {
    final client = _TestMissavClient(_details());
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();
    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        _testVideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    final opening = Completer<void>();
    session.nextLoadCompleter = opening;
    await _chooseSetting(tester, '${l10n.videoQuality}: 720p');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('video-playback-loading')),
      findsOneWidget,
    );

    session.emitError('The media relay returned HTTP 502.');
    await tester.pump();
    expect(find.text(l10n.videoPlaybackFailed), findsOneWidget);
    expect(find.byKey(const ValueKey('video-playback-loading')), findsNothing);

    opening.complete();
    await tester.pump();
  });

  _testPlayerWidget(
    'fullscreen playback recovery stays usable on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final library = await _testLibrary();
      final session = _FakePlaybackSession();
      final navigatorKey = GlobalKey<NavigatorState>();
      var callbackSawFullscreenRoute = true;

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: VideoPlaybackPanel(
              videoId: 'dvd-1',
              title: 'Fixture video',
              library: library,
              streams: _details().streams,
              sessionFactory: () => session,
              platform: _TestVideoPlayerPlatform(),
              onVerifyAccess: () async {
                callbackSawFullscreenRoute = navigatorKey.currentState!
                    .canPop();
              },
              onOpenSource: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      session.nextLoadError = StateError('Fixture stream error');
      await _chooseSetting(tester, '${l10n.videoQuality}: 720p');
      await tester.pumpAndSettle();

      expect(find.text(l10n.videoPlaybackFailed), findsOneWidget);
      expect(find.byTooltip(l10n.videoFullscreen), findsOneWidget);
      final verifyAccess = find.text(l10n.videoVerifyAccess);
      final verifyRect = tester.getRect(verifyAccess);
      expect(verifyRect.left, greaterThanOrEqualTo(0));
      expect(verifyRect.right, lessThanOrEqualTo(360));
      expect(verifyRect.top, greaterThanOrEqualTo(0));
      expect(verifyRect.bottom, lessThanOrEqualTo(800));

      await tester.tap(verifyAccess);
      await tester.pumpAndSettle();

      expect(callbackSawFullscreenRoute, isFalse);
      expect(
        find.byKey(const ValueKey('video-fullscreen-placeholder')),
        findsNothing,
      );
      expect(find.text(l10n.videoVerifyAccess), findsOneWidget);
    },
  );

  for (final failFirstRequest in [false, true]) {
    _testPlayerWidget(
      'favorite blocks overlapping submissions and allows retry (failure=$failFirstRequest)',
      (tester) async {
        final response = Completer<void>();
        final client = _TestMissavClient(_details(), loggedIn: true)
          ..favoriteResponse = response.future;
        final library = await _testLibrary();
        final downloads = _TestVideoDownloads(client: client, library: library);
        final session = _FakePlaybackSession();
        await tester.pumpWidget(
          _app(
            client,
            library,
            downloads,
            _testVideoDetailsScreen(
              video: _video(),
              sessionFactory: () => session,
            ),
          ),
        );
        await tester.pumpAndSettle();
        try {
          final favorite = find.byIcon(Icons.bookmark_outline);
          await tester.tap(favorite);
          await tester.pump();
          final button = tester.widget<IconButton>(
            find.ancestor(of: favorite, matching: find.byType(IconButton)),
          );
          expect(button.onPressed, isNull);
          await tester.tap(favorite);
          await tester.pump();
          expect(client.videoFavoriteChanges, [true]);

          if (failFirstRequest) {
            response.completeError(StateError('Source unavailable'));
            await tester.pumpAndSettle();
            final l10n = await S.delegate.load(const Locale('en'));
            await tester.tap(find.text(l10n.cancel));
          } else {
            response.complete();
          }
          await tester.pumpAndSettle();
          final icon = failFirstRequest
              ? Icons.bookmark_outline
              : Icons.bookmark;
          expect(find.byIcon(icon), findsOneWidget);
          client.favoriteResponse = null;
          await tester.tap(find.byIcon(icon));
          await tester.pumpAndSettle();
          expect(client.videoFavoriteChanges, [true, failFirstRequest]);
          expect(
            find.byIcon(
              failFirstRequest ? Icons.bookmark : Icons.bookmark_outline,
            ),
            findsOneWidget,
          );
        } finally {
          if (!response.isCompleted) response.complete();
          await tester.pumpAndSettle();
        }
      },
    );
  }

  _testPlayerWidget('account change clears and reloads detail favorite state', (
    tester,
  ) async {
    final client = _TestMissavClient(_details());
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        _testVideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bookmark_outline), findsOneWidget);

    client.switchAccount(isFavorite: true);
    await tester.pumpAndSettle();

    expect(client.detailsCalls, 2);
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
  });

  _testPlayerWidget('actor favorites wait for account confirmation', (
    tester,
  ) async {
    const actor = VideoLink(
      label: 'Fixture actor',
      url: 'https://missav.ai/cn/actress/fixture',
      kind: VideoLinkKind.actor,
    );
    final details = VideoDetails(
      video: _video(),
      actors: [actor],
      streams: _details().streams,
    );
    final client = _TestMissavClient(details)
      ..readyDetails = details
      ..detailsCompleter = Completer<VideoDetails>();
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();
    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        _testVideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();
    final s = await S.delegate.load(const Locale('en'));
    await tester.ensureVisible(find.byTooltip(actor.label));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(actor.label));
    await tester.pumpAndSettle();
    for (final label in [s.videoFavoriteActor, s.videoUnfavoriteActor]) {
      final item = tester.widget<PopupMenuItem<String>>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(PopupMenuItem<String>),
        ),
      );
      expect(item.enabled, isFalse);
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    client.switchAccount(isFavorite: false);
    client.detailsCompleter!.complete(details);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip(actor.label));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(actor.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(s.videoFavoriteActor));
    await tester.pumpAndSettle();
    expect(client.actorFavoriteChanges, [true]);
    expect(find.text(s.videoLoginRequired), findsNothing);
  });

  _testPlayerWidget(
    'actor menu sends the selected favorite state to the source',
    (tester) async {
      const actor = VideoLink(
        label: 'Fixture actor',
        url: 'https://missav.ai/cn/actress/fixture',
        kind: VideoLinkKind.actor,
      );
      final client = _TestMissavClient(
        VideoDetails(
          video: _video(),
          actors: [actor],
          streams: _details().streams,
        ),
        loggedIn: true,
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();

      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = await S.delegate.load(const Locale('en'));
      await tester.ensureVisible(find.byTooltip('Fixture actor'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Fixture actor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.videoFavoriteActor));
      await tester.pumpAndSettle();

      expect(client.actorFavoriteChanges, [true]);
    },
  );

  _testPlayerWidget(
    'video metadata groups linked creators before actors and tags',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const pageGenre = VideoLink(
        label: 'Same name',
        url: 'https://missav.ai/cn/genres/same-name',
        kind: VideoLinkKind.category,
      );
      const apiGenre = VideoLink(
        label: 'Same name',
        url: 'https://missav.ai/ja/genres/same-name',
        kind: VideoLinkKind.category,
      );
      const makerLink = VideoLink(
        label: 'Same name',
        url: 'https://missav.ai/cn/makers/same-name',
        kind: VideoLinkKind.studio,
      );
      const shortMakerLink = VideoLink(
        label: 'M',
        url: 'https://missav.ai/cn/makers/m',
        kind: VideoLinkKind.studio,
      );
      const labelLink = VideoLink(
        label: 'Linked label',
        url: 'https://missav.ai/cn/labels/linked-label',
        kind: VideoLinkKind.category,
      );
      const seriesLink = VideoLink(
        label: 'Linked series',
        url: 'https://missav.ai/cn/series/linked-series',
        kind: VideoLinkKind.category,
      );
      const directorLink = VideoLink(
        label: 'Linked director',
        url: 'https://missav.ai/cn/directors/linked-director',
        kind: VideoLinkKind.other,
      );
      const linklessTag = VideoLink(
        label: 'Linkless tag',
        url: '   ',
        kind: VideoLinkKind.tag,
      );
      const linklessActor = VideoLink(
        label: 'Linkless actor',
        url: '',
        kind: VideoLinkKind.actor,
      );
      const actor = VideoLink(
        label: 'Saved actor',
        url: 'https://missav.ai/cn/actresses/saved-actor',
        kind: VideoLinkKind.actor,
      );
      final extraGenres = List.generate(
        8,
        (index) => VideoLink(
          label: 'Tag $index',
          url: 'https://missav.ai/cn/genres/tag-$index',
          kind: VideoLinkKind.tag,
        ),
      );
      final video = VideoItem(
        id: 'metadata-video',
        title: 'Metadata video',
        pageUrl: 'https://missav.ai/cn/metadata-video',
        actors: [actor, linklessActor],
        tags: [
          apiGenre,
          shortMakerLink,
          makerLink,
          labelLink,
          seriesLink,
          directorLink,
          linklessTag,
          ...extraGenres,
        ],
        makers: ['Same name', 'Linkless maker'],
        labels: ['Linkless label'],
        series: ['Linkless series'],
        directors: ['Linkless director'],
      );
      final details = VideoDetails(
        video: video,
        actors: const [actor, linklessActor],
        tags: [
          pageGenre,
          shortMakerLink,
          makerLink,
          labelLink,
          seriesLink,
          directorLink,
          linklessTag,
          ...extraGenres,
        ],
        metadata: const {
          'Director': 'Raw director',
          'Maker': 'Linkless maker',
          'Genres': 'Linkless tag',
          'Duration': '128 minutes',
        },
        streams: _details().streams,
      );
      final client = _TestMissavClient(details);
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();

      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(video: video, sessionFactory: () => session),
        ),
      );
      await tester.pumpAndSettle();

      final l10n = await S.delegate.load(const Locale('en'));
      for (final title in [
        l10n.videoDetailCreators,
        l10n.videoDetailActors,
        l10n.tagLabel,
      ]) {
        expect(find.text(title), findsOneWidget);
      }
      expect(find.text(l10n.videoActorFavorites), findsNothing);
      expect(find.text(l10n.videoFilterGenre), findsNothing);
      expect(find.text(l10n.videoCardDirectors), findsNothing);
      expect(find.text('Same name'), findsNWidgets(2));
      expect(
        tester.getTopLeft(find.text(l10n.videoDetailCreators)).dy,
        lessThan(tester.getTopLeft(find.text(l10n.videoDetailActors)).dy),
      );
      expect(
        tester.getTopLeft(find.text(l10n.videoDetailActors)).dy,
        lessThan(tester.getTopLeft(find.text(l10n.tagLabel)).dy),
      );
      expect(find.text('Linked label'), findsOneWidget);
      expect(find.text('Linked series'), findsOneWidget);
      expect(
        tester.getCenter(find.text('Linked label')).dy,
        closeTo(tester.getCenter(find.text('Same name').first).dy, 0.1),
      );
      expect(
        tester.getCenter(find.text('Linked series')).dy,
        closeTo(tester.getCenter(find.text('Same name').first).dy, 0.1),
      );
      for (final label in [
        'Linkless maker',
        'Linkless label',
        'Linkless series',
        'Linkless director',
        'Linkless tag',
        'Linkless actor',
        'Linked director',
      ]) {
        expect(find.text(label), findsNothing, reason: label);
      }
      expect(
        find.text('Director: Raw director', findRichText: true),
        findsNothing,
      );
      expect(
        find.text('Maker: Linkless maker', findRichText: true),
        findsNothing,
      );
      expect(
        find.text('Genres: Linkless tag', findRichText: true),
        findsNothing,
      );
      expect(
        find.text('Duration: 128 minutes', findRichText: true),
        findsOneWidget,
      );
      Rect pillRect(String label) => tester.getRect(
        find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .first,
      );
      for (final (title, label) in [
        (l10n.videoDetailCreators, 'M'),
        (l10n.videoDetailActors, actor.label),
        (l10n.tagLabel, 'Same name'),
      ]) {
        final heading = tester.getRect(find.text(title));
        final pill = label == 'Same name'
            ? tester.getRect(
                find
                    .ancestor(
                      of: find.text(label).last,
                      matching: find.byType(Container),
                    )
                    .first,
              )
            : pillRect(label);
        expect(pill.left, closeTo(heading.left, .1));
        expect(pill.top - heading.bottom, closeTo(8, .1));
      }
      expect(
        tester.getTopLeft(find.text(l10n.videoDetailActors)).dy -
            pillRect(seriesLink.label).bottom,
        closeTo(16, .1),
      );
      expect(
        tester.getTopLeft(find.text(l10n.tagLabel)).dy -
            pillRect(actor.label).bottom,
        closeTo(16, .1),
      );
      final semantics = tester.ensureSemantics();
      try {
        expect(client.browsedUrls, isEmpty);

        final linkedLabels = find.text('Same name');
        expect(linkedLabels, findsNWidgets(2));
        final colors = Theme.of(tester.element(linkedLabels.first)).colorScheme;
        final genreSurface = find
            .ancestor(of: linkedLabels.last, matching: find.byType(Container))
            .first;
        final makerSurface = find
            .ancestor(of: linkedLabels.first, matching: find.byType(Container))
            .first;
        final makerSize = tester.getSize(makerSurface);
        expect(
          (tester.widget<Container>(genreSurface).decoration! as BoxDecoration)
              .color,
          colors.primaryContainer,
        );
        expect(
          (tester.widget<Container>(makerSurface).decoration! as BoxDecoration)
              .color,
          colors.secondaryContainer,
        );
        for (final (label, background, foreground) in [
          (
            'Linked label',
            colors.secondaryContainer,
            colors.onSecondaryContainer,
          ),
          ('Linked series', colors.errorContainer, colors.onErrorContainer),
        ]) {
          final text = find.text(label);
          final surface = find
              .ancestor(of: text, matching: find.byType(Container))
              .first;
          expect(
            (tester.widget<Container>(surface).decoration! as BoxDecoration)
                .color,
            background,
          );
          expect(tester.widget<Text>(text).style?.color, foreground);
        }
        final linkedControl = find.ancestor(
          of: linkedLabels.last,
          matching: find.byType(InkWell),
        );
        await tester.ensureVisible(linkedLabels.last);
        await tester.pumpAndSettle();
        final actorTarget = tester.getRect(find.byTooltip(actor.label));
        expect(actorTarget, pillRect(actor.label));
        expect(
          tester
              .getSemantics(linkedControl)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
        expect(
          tester
              .getSemantics(linkedControl)
              .getSemanticsData()
              .flagsCollection
              .isButton,
          isTrue,
        );
        final button = find.ancestor(
          of: linkedLabels.last,
          matching: find.byType(TextButton),
        );
        await tester.tapAt(tester.getTopLeft(button) + const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(client.browsedUrls, [pageGenre.url]);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(320, 1600);
        await tester.pumpAndSettle();
        final videoTags = find.ancestor(
          of: find.text(extraGenres.first.label),
          matching: find.byType(Wrap),
        );
        final videoTagsSize = tester.getSize(videoTags);
        final tagRows = extraGenres.map((tag) => pillRect(tag.label)).toList();
        expect(tagRows.last.top, greaterThan(tagRows.first.top));
        for (var index = 1; index < tagRows.length; index++) {
          if (tagRows[index].top > tagRows[index - 1].top) {
            expect(
              tagRows[index].top - tagRows[index - 1].bottom,
              closeTo(4, .1),
            );
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          _app(
            client,
            library,
            downloads,
            Scaffold(
              body: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const WorkCreatorChipsSection(
                      work: Work(
                        id: 1,
                        title: 'Audio reference',
                        name: 'Same name',
                      ),
                    ),
                    WorkTagChipsSection(
                      tags: [
                        const Tag(id: -1, name: 'Same name'),
                        for (var index = 0; index < extraGenres.length; index++)
                          Tag(id: -2 - index, name: extraGenres[index].label),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final audioPill = find
            .ancestor(
              of: find.text('Same name').first,
              matching: find.byType(Container),
            )
            .first;
        expect(tester.getSize(audioPill), makerSize);
        expect(
          tester
              .getSize(
                find.ancestor(
                  of: find.text(extraGenres.first.label),
                  matching: find.byType(Wrap),
                ),
              )
              .height,
          videoTagsSize.height,
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  _testPlayerWidget('details hide groups without linked entries', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const video = VideoItem(
      id: 'unlinked-metadata',
      title: 'No linked metadata',
      pageUrl: 'https://missav.ai/cn/unlinked-metadata',
      makers: ['Name only maker'],
      labels: ['Name only label'],
      series: ['Name only series'],
    );
    final client = _TestMissavClient(
      const VideoDetails(
        video: video,
        actors: [
          VideoLink(
            label: 'Name only actor',
            url: '',
            kind: VideoLinkKind.actor,
          ),
        ],
        tags: [
          VideoLink(label: 'Name only tag', url: ' ', kind: VideoLinkKind.tag),
        ],
        metadata: {'Director': 'Name only director', 'Duration': '128 minutes'},
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();
    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        _testVideoDetailsScreen(video: video, sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    for (final title in [
      l10n.videoDetailCreators,
      l10n.videoDetailActors,
      l10n.tagLabel,
    ]) {
      expect(find.text(title), findsNothing);
    }
    expect(find.textContaining('Name only', findRichText: true), findsNothing);
    expect(
      find.text('Duration: 128 minutes', findRichText: true),
      findsOneWidget,
    );
  });

  for (final size in const [Size(320, 800), Size(1200, 800)]) {
    _testPlayerWidget(
      'video details keep their layout and metadata accessible at ${size.width.toInt()} px',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        const video = VideoItem(
          id: 'layout-video',
          title:
              'A complete video title that wraps across several lines on a narrow screen',
          pageUrl: 'https://missav.ai/cn/layout-video',
        );
        const actor = VideoLink(
          label: 'Fixture actor',
          url: 'https://missav.ai/cn/actress/fixture',
          kind: VideoLinkKind.actor,
        );
        const tag = VideoLink(
          label: 'Fixture tag',
          url: 'https://missav.ai/cn/genre/fixture',
          kind: VideoLinkKind.tag,
        );
        const related = VideoItem(
          id: 'layout-related',
          title: 'Related fixture video',
          pageUrl: 'https://missav.ai/cn/layout-related',
        );
        const description = 'Selectable video description.';
        final details = VideoDetails(
          video: video,
          metadata: const {
            'Source note':
                'A source note long enough to wrap while preserving the complete metadata value',
            'Duration': '128 minutes',
          },
          description: description,
          actors: const [actor],
          tags: const [tag],
          related: const [related],
          streams: _details().streams,
        );
        final client = _TestMissavClient(details);
        final library = await _testLibrary();
        final downloads = _TestVideoDownloads(client: client, library: library);
        final session = _FakePlaybackSession();

        await tester.pumpWidget(
          _app(
            client,
            library,
            downloads,
            _testVideoDetailsScreen(
              video: video,
              sessionFactory: () => session,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final player = find.byType(VideoPlaybackPanel);
        final isLandscape = size.width > size.height;
        final detailsList = find.byKey(
          PageStorageKey(
            'video-details-${isLandscape ? 'landscape' : 'portrait'}-${video.id}',
          ),
        );
        final detailsScrollable = find
            .descendant(of: detailsList, matching: find.byType(Scrollable))
            .first;
        final listRect = tester.getRect(detailsList);
        final playerRect = tester.getRect(player);
        if (isLandscape) {
          final inlineTop =
              MediaQueryData.fromView(tester.view).viewPadding.top +
              kToolbarHeight;
          final inlineHeight = size.height - inlineTop;
          final paneWidth = size.width * .4;
          final expectedPlayerWidth = paneWidth < inlineHeight * 16 / 9
              ? paneWidth
              : inlineHeight * 16 / 9;
          expect(listRect.left, closeTo(paneWidth, .1));
          expect(listRect.right, closeTo(size.width, .1));
          expect(listRect.top, closeTo(inlineTop, .1));
          expect(
            playerRect.left,
            closeTo((paneWidth - expectedPlayerWidth) / 2, .1),
          );
          expect(
            playerRect.right,
            closeTo((paneWidth + expectedPlayerWidth) / 2, .1),
          );
          expect(playerRect.center.dx, closeTo(paneWidth / 2, .1));
          expect(
            playerRect.top,
            closeTo(
              inlineTop + (inlineHeight - expectedPlayerWidth * 9 / 16) / 2,
              .1,
            ),
          );
          expect(playerRect.height, closeTo(playerRect.width * 9 / 16, .1));
        } else {
          expect(playerRect.left, closeTo(listRect.left, .1));
          expect(playerRect.width, closeTo(listRect.width, .1));
          expect(playerRect.height, closeTo(playerRect.width * 9 / 16, .1));
          expect(playerRect.top, closeTo(listRect.top + 4, .1));
        }

        final bodyTitle = find
            .descendant(
              of: detailsList,
              matching: find.text(video.title, findRichText: true),
            )
            .last;
        expect(bodyTitle, findsOneWidget);
        final titleRect = tester.getRect(bodyTitle);
        expect(
          titleRect.top,
          greaterThanOrEqualTo(
            isLandscape ? listRect.top + 4 : playerRect.bottom + 16,
          ),
        );
        expect(titleRect.left, closeTo(listRect.left + 16, .1));
        expect(titleRect.right, closeTo(listRect.right - 16, .1));
        expect(
          find.descendant(
            of: detailsList,
            matching: find.text(
              'Source note: A source note long enough to wrap while preserving the complete metadata value',
              findRichText: true,
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: detailsList,
            matching: find.text('Duration: 128 minutes', findRichText: true),
          ),
          findsOneWidget,
        );
        // Start below the player so its fullscreen gesture does not consume the drag.
        await tester.dragFrom(
          Offset(listRect.center.dx, listRect.bottom - 24),
          const Offset(0, -400),
        );
        await tester.pumpAndSettle();
        final descriptionText = find.byType(SelectableText);
        await tester.scrollUntilVisible(
          descriptionText,
          200,
          scrollable: detailsScrollable,
        );
        await tester.pumpAndSettle();
        expect(descriptionText, findsOneWidget);
        expect(
          tester.widget<SelectableText>(descriptionText).data,
          description,
        );

        final semantics = tester.ensureSemantics();
        try {
          final actorButton = find.byTooltip(actor.label);
          await tester.scrollUntilVisible(
            actorButton,
            200,
            scrollable: detailsScrollable,
          );
          await tester.pumpAndSettle();
          final actorSemantics = tester
              .getSemantics(actorButton)
              .getSemanticsData();
          expect(actorSemantics.hasAction(SemanticsAction.tap), isTrue);
          await tester.tap(actorButton);
          await tester.pumpAndSettle();
          final l10n = await S.delegate.load(const Locale('en'));
          for (final label in [
            l10n.videoCatalog,
            l10n.videoFavoriteActor,
            l10n.videoUnfavoriteActor,
            l10n.videoOpenSource,
          ]) {
            expect(
              find.ancestor(
                of: find.text(label),
                matching: find.byType(PopupMenuItem<String>),
              ),
              findsOneWidget,
            );
          }
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();

          final tagLabel = find.text(tag.label);
          final tagChip = find.ancestor(
            of: tagLabel,
            matching: find.byType(InkWell),
          );
          await tester.scrollUntilVisible(
            tagChip,
            200,
            scrollable: detailsScrollable,
          );
          await tester.pumpAndSettle();
          final tagSemantics = tester.getSemantics(tagChip).getSemanticsData();
          expect(tagSemantics.hasAction(SemanticsAction.tap), isTrue);
          final colors = Theme.of(tester.element(tagChip)).colorScheme;
          final tagSurface = find
              .ancestor(of: tagLabel, matching: find.byType(Container))
              .first;
          expect(
            (tester.widget<Container>(tagSurface).decoration! as BoxDecoration)
                .color,
            colors.primaryContainer,
          );
          expect(
            tester.widget<Text>(tagLabel).style?.color,
            colors.onPrimaryContainer,
          );
          await tester.scrollUntilVisible(
            find.text(related.title),
            200,
            scrollable: detailsScrollable,
          );
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: detailsList,
              matching: find.text(related.title),
            ),
            findsOneWidget,
          );
        } finally {
          semantics.dispose();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  _testPlayerWidget(
    'video details keep the landscape player below the AppBar in a short window',
    (tester) async {
      tester.view.physicalSize = const Size(2000, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final layout = find.byKey(const ValueKey('video-playback-layout'));
      final infoPane = find.byKey(
        const PageStorageKey<String>('video-details-landscape-dvd-1'),
      );
      final playerRect = tester.getRect(layout);
      final infoRect = tester.getRect(infoPane);
      const inlineTop = kToolbarHeight;
      const inlineHeight = 400 - inlineTop;
      const playerWidth = inlineHeight * 16 / 9;

      expect(find.byType(AppBar), findsOneWidget);
      expect(infoRect.top, closeTo(inlineTop, .1));
      expect(infoRect.height, closeTo(inlineHeight, .1));
      expect(playerRect.top, closeTo(inlineTop, .1));
      expect(playerRect.height, closeTo(inlineHeight, .1));
      expect(playerRect.width, closeTo(playerWidth, .1));
      expect(playerRect.bottom, lessThanOrEqualTo(400));
      expect(tester.takeException(), isNull);
    },
  );

  _testPlayerWidget(
    'a new media session reloads the stream for the same account',
    (tester) async {
      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      client.reconnect();
      await tester.pumpAndSettle();
      expect(client.isLoggedIn, isFalse);
      expect(client.detailsCalls, 2);
      expect(session.loadStreamCount, 2);
      expect(session.lastStreamUrl, 'http://127.0.0.1:1235/video.m3u8');
    },
  );

  _testPlayerWidget(
    'covering or backgrounding the detail pauses without resuming',
    (tester) async {
      final client = _TestMissavClient(_details());
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final navigator = Navigator.of(
        tester.element(find.byType(VideoDetailsScreen)),
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Cover route')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(session.pauseCount, greaterThan(0));
      navigator.pop();
      await tester.pumpAndSettle();
      expect(session.playCount, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(session.pauseCount, greaterThan(1));
      expect(session.playCount, 0);
    },
  );

  _testPlayerWidget(
    'finishing a download keeps playback until details reopen',
    (tester) async {
      final client = _TestMissavClient(_details());
      final library = await _testLibrary(position: const Duration(seconds: 12));
      final downloads = _TestVideoDownloads(
        client: client,
        library: library,
        task: VideoDownloadTask(
          id: 'dvd-1',
          video: _video(),
          quality: 'Auto',
          isHls: true,
          status: VideoDownloadStatus.downloading,
          localPath: '/offline/video/index.m3u8',
        ),
      );
      var session = _FakePlaybackSession();
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => _testVideoDetailsScreen(
                      video: _video(),
                      sessionFactory: () => session,
                    ),
                  ),
                ),
                child: const Text('Open video'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open video'));
      await tester.pumpAndSettle();
      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoPlay));
      await tester.pump();
      await session.seek(const Duration(seconds: 44));

      downloads.completeDownload();
      await tester.pumpAndSettle();

      expect(session.loadStreamCount, 1);
      expect(session.loadFileCount, 0);
      expect(session.snapshot.value.position, const Duration(seconds: 44));
      expect(session.snapshot.value.playing, isTrue);
      expect(client.detailsCalls, 1);

      final playerBack = find.byKey(const ValueKey('video-player-back'));
      await tester.ensureVisible(playerBack);
      await tester.tap(playerBack);
      await tester.pumpAndSettle();
      session = _FakePlaybackSession();
      await tester.tap(find.text('Open video'));
      await tester.pumpAndSettle();
      expect(session.loadFileCount, 1);
      expect(session.localPath, downloads.task!.localPath);
      expect(session.loadStreamCount, 0);
      expect(session.lastPosition, const Duration(seconds: 44));
      expect(client.detailsCalls, 1);
    },
  );

  _testPlayerWidget('downloaded details skip online detail loading', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = _TestMissavClient(
      _details(),
      initializeError: StateError('Secure storage unavailable'),
    );
    final library = await _testLibrary();
    const actor = VideoLink(
      label: 'Saved actor',
      url: 'https://missav.ai/cn/actresses/saved-actor',
      kind: VideoLinkKind.actor,
    );
    const savedVideo = VideoItem(
      id: 'dvd-1',
      title: 'Saved video',
      pageUrl: 'https://missav.ai/cn/dvd-1',
      actors: [actor],
      tags: [
        VideoLink(
          label: 'Saved genre',
          url: 'https://missav.ai/cn/genres/saved-genre',
          kind: VideoLinkKind.category,
        ),
        VideoLink(
          label: 'Legacy maker',
          url: 'https://missav.ai/cn/makers/legacy-maker',
          kind: VideoLinkKind.studio,
        ),
        VideoLink(
          label: 'Legacy label',
          url: 'https://missav.ai/cn/labels/legacy-label',
          kind: VideoLinkKind.category,
        ),
        VideoLink(
          label: 'Legacy series',
          url: 'https://missav.ai/cn/series/legacy-series',
          kind: VideoLinkKind.category,
        ),
        VideoLink(
          label: 'Legacy director',
          url: 'https://missav.ai/cn/directors/legacy-director',
          kind: VideoLinkKind.other,
        ),
      ],
      makers: ['Legacy maker', 'Linkless maker'],
      labels: ['Linkless label'],
      series: ['Linkless series'],
      directors: ['Linkless director'],
    );
    const task = VideoDownloadTask(
      id: 'dvd-1',
      video: savedVideo,
      quality: 'Auto',
      isHls: true,
      status: VideoDownloadStatus.completed,
      progress: 1,
      localPath: '/offline/video/index.m3u8',
    );
    final downloads = _TestVideoDownloads(
      client: client,
      library: library,
      task: task,
    );
    final session = _FakePlaybackSession();

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        _testVideoDetailsScreen(
          video: _video(),
          downloadedTask: task,
          sessionFactory: () => session,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(client.detailsCalls, 0);
    expect(client.initializeCalls, 0);
    expect(session.loadFileCount, 1);
    expect(session.localPath, task.localPath);
    expect(session.loadStreamCount, 0);
    final l10n = await S.delegate.load(const Locale('en'));
    for (final title in [
      l10n.videoDetailCreators,
      l10n.videoDetailActors,
      l10n.tagLabel,
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('Legacy maker'), findsOneWidget);
    for (final label in [
      'Saved genre',
      'Legacy label',
      'Legacy series',
      'Saved actor',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    for (final label in [
      'Linkless maker',
      'Linkless label',
      'Linkless series',
      'Legacy director',
      'Linkless director',
    ]) {
      expect(find.text(label), findsNothing, reason: label);
    }
    expect(
      find.ancestor(
        of: find.text('Legacy maker'),
        matching: find.byType(InkWell),
      ),
      findsOneWidget,
    );
  });

  _testPlayerWidget(
    'downloads wait for metadata returned with the parsed details',
    (tester) async {
      final parsedVideo = VideoItem(
        id: _video().id,
        title: _video().title,
        pageUrl: _video().pageUrl,
        releaseDate: '2025-01-02',
        actors: const [
          VideoLink(
            label: 'Parsed actor',
            url: 'https://missav.ai/cn/actress/parsed',
            kind: VideoLinkKind.actor,
          ),
        ],
        tags: const [
          VideoLink(
            label: 'Parsed tag',
            url: 'https://missav.ai/cn/genre/parsed',
            kind: VideoLinkKind.tag,
          ),
        ],
        hasSubtitles: true,
        isUncensored: true,
      );
      final client =
          _TestMissavClient(
              VideoDetails(video: parsedVideo, streams: _details().streams),
            )
            ..readyDetails = _details()
            ..detailsCompleter = Completer<VideoDetails>();
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();

      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = await S.delegate.load(const Locale('en'));
      final downloadButton = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == l10n.download,
        ),
      );
      expect(downloadButton.onPressed, isNull);
      expect(downloads.lastAddedVideo, isNull);
      client.detailsCompleter!.complete(client.detailsResult);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.download));
      await tester.pumpAndSettle();

      expect(identical(downloads.lastAddedVideo, parsedVideo), isTrue);
      expect(downloads.lastAddedVideo?.releaseDate, '2025-01-02');
      expect(downloads.lastAddedVideo?.actors.single.label, 'Parsed actor');
      expect(downloads.lastAddedVideo?.tags.single.label, 'Parsed tag');
      expect(downloads.lastAddedVideo?.hasSubtitles, isTrue);
      expect(downloads.lastAddedVideo?.isUncensored, isTrue);
    },
  );

  _testPlayerWidget(
    'detail layout fits 360px and 1280px windows at 1.3 text scale',
    (tester) async {
      final client = _TestMissavClient(
        VideoDetails(
          video: _video(),
          description: 'A fixture description that exercises wrapping.',
          metadata: const {'Studio': 'A studio with a longer name'},
          actors: const [
            VideoLink(
              label: 'A performer with a long name',
              url: 'https://missav.ai/cn/actress/fixture',
              kind: VideoLinkKind.actor,
            ),
          ],
          tags: const [
            VideoLink(
              label: 'A category with a longer name',
              url: 'https://missav.ai/cn/genre/fixture',
              kind: VideoLinkKind.category,
            ),
          ],
          related: [
            for (var index = 0; index < 4; index++)
              VideoItem(
                id: 'related-$index',
                title: 'Related fixture video $index',
                pageUrl: 'https://missav.ai/cn/related-$index',
              ),
          ],
          streams: const [
            VideoStream(label: 'Auto', url: 'https://cdn.example/video.m3u8'),
          ],
        ),
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();

      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
          ),
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(1280, 900);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );

  _testPlayerWidget('sleep timer completion suppresses related auto next', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'video_player_v1_repeat_mode': VideoPlayerRepeatMode.related.index,
    });
    final library = VideoLibrary(
      preferences: await SharedPreferences.getInstance(),
    );
    await library.initialize();
    final timer = VideoSleepTimer.shared;
    timer.cancel();
    timer.setAction(VideoSleepTimerAction.pause);
    timer.setFinishCurrentVideo(true);
    final session = _FakePlaybackSession();
    var relatedCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        home: Scaffold(
          body: VideoPlaybackPanel(
            videoId: 'dvd-1',
            library: library,
            streams: _details().streams,
            sessionFactory: () => session,
            platform: _TestVideoPlayerPlatform(),
            onPlayNextRelated: () async {
              relatedCalls++;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.videoPlay));
    await tester.pumpAndSettle();

    timer.start(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 2));
    expect(timer.waitingForCompletion, isTrue);
    session.complete();
    await tester.pumpAndSettle();

    expect(relatedCalls, 0);
    expect(session.pauseCount, 1);
    timer.cancel();
    timer.setFinishCurrentVideo(false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  _testPlayerWidget(
    'finish current sleep timer pauses single loop until pause completes',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final library = await _testLibrary();
      await (await SharedPreferences.getInstance()).setInt(
        'video_player_v1_repeat_mode',
        VideoPlayerRepeatMode.single.index,
      );
      final timer = VideoSleepTimer.shared;
      timer.cancel();
      timer.setAction(VideoSleepTimerAction.pause);
      timer.setFinishCurrentVideo(false);
      final session = _FakeAdvancedPlaybackSession();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          home: Scaffold(
            body: VideoPlaybackPanel(
              videoId: 'dvd-1',
              library: library,
              streams: _details().streams,
              sessionFactory: () => session,
              platform: _FakeDesktopPiPPlatform(initiallyInPip: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(session.loopModes.last, isTrue);

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoPlay));
      await tester.pumpAndSettle();
      timer.setFinishCurrentVideo(true);
      timer.start(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 2));
      expect(timer.waitingForCompletion, isTrue);
      expect(session.loopModes.last, isFalse);

      session.complete();
      await tester.pumpAndSettle();
      expect(session.pauseCount, 1);
      expect(timer.actionInProgress, isFalse);
      expect(session.loopModes.last, isTrue);
      timer.cancel();
      timer.setFinishCurrentVideo(false);
      expect(tester.takeException(), isNull);
    },
  );

  for (final fullscreen in [false, true]) {
    _testPlayerWidget(
      'auto next waits for player menus to close with fullscreen=$fullscreen',
      (tester) async {
        final library = await _testLibrary();
        await (await SharedPreferences.getInstance()).setInt(
          'video_player_v1_repeat_mode',
          VideoPlayerRepeatMode.related.index,
        );
        final session = _FakePlaybackSession();
        var nextCalls = 0;
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            supportedLocales: S.supportedLocales,
            localizationsDelegates: S.localizationsDelegates,
            home: Scaffold(
              body: VideoPlaybackPanel(
                videoId: 'dvd-1',
                library: library,
                streams: _details().streams,
                sessionFactory: () => session,
                platform: _TestVideoPlayerPlatform(),
                onPlayNextRelated: () async {
                  nextCalls++;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (fullscreen) {
          await tester.tap(
            find.byKey(const ValueKey('video-fullscreen-control')),
          );
          await tester.pumpAndSettle();
        }
        await _openSettings(tester);
        session.complete();
        await tester.pumpAndSettle();
        expect(nextCalls, 0);

        final s = await S.delegate.load(const Locale('en'));
        await _ensureMoreMenuItemVisible(
          tester,
          find.text(s.videoPlayerSettings),
        );
        await tester.tap(find.text(s.videoPlayerSettings));
        await tester.pumpAndSettle();
        expect(find.byType(VideoPlaybackSettingsScreen), findsOneWidget);
        expect(nextCalls, 0);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(nextCalls, 1);
        session.emitSnapshot(buffering: false);
        await tester.pumpAndSettle();
        expect(nextCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final target in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    _testPlayerWidget(
      'auto next waits for picture-in-picture to close on $target',
      (tester) async {
        debugDefaultTargetPlatformOverride = target;
        final library = await _testLibrary();
        await (await SharedPreferences.getInstance()).setInt(
          'video_player_v1_repeat_mode',
          VideoPlayerRepeatMode.related.index,
        );
        final session = _FakePlaybackSession();
        final platform = _FakeDesktopPiPPlatform(
          platform: target,
          initiallyInPip: false,
        );
        var nextCalls = 0;
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            supportedLocales: S.supportedLocales,
            localizationsDelegates: S.localizationsDelegates,
            home: Scaffold(
              body: VideoPlaybackPanel(
                videoId: 'dvd-1',
                library: library,
                streams: _details().streams,
                sessionFactory: () => session,
                platform: platform,
                onPlayNextRelated: () async {
                  nextCalls++;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        platform.startPictureInPicture();
        await tester.pumpAndSettle();
        session.complete();
        await tester.pumpAndSettle();
        expect(nextCalls, 0);

        await platform.exitPictureInPicture();
        await tester.pumpAndSettle();
        expect(nextCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  _testPlayerWidget('auto next replaces completed detail routes', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const first = VideoItem(
      id: 'first',
      title: 'First video',
      pageUrl: 'https://missav.ai/cn/first',
    );
    const second = VideoItem(
      id: 'second',
      title: 'Second video',
      pageUrl: 'https://missav.ai/cn/second',
    );
    const third = VideoItem(
      id: 'third',
      title: 'Third video',
      pageUrl: 'https://missav.ai/cn/third',
    );
    final client = _TestMissavClient(_details())
      ..detailsForVideo = (video) => VideoDetails(
        video: video,
        streams: _details().streams,
        related: switch (video.id) {
          'first' => const [second],
          'second' => const [third],
          _ => const [],
        },
      );
    final library = await _testLibrary();
    await (await SharedPreferences.getInstance()).setInt(
      'video_player_v1_repeat_mode',
      VideoPlayerRepeatMode.related.index,
    );
    final downloads = _TestVideoDownloads(client: client, library: library);
    final sessions = <_FakePlaybackSession>[];

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        _testVideoDetailsScreen(
          video: first,
          sessionFactory: () {
            final session = _FakePlaybackSession();
            sessions.add(session);
            return session;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(sessions, hasLength(1));

    sessions[0].complete();
    await tester.pumpAndSettle();
    expect(find.byType(VideoDetailsScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Second video'),
      ),
      findsOneWidget,
    );
    expect(sessions, hasLength(2));
    expect(sessions[0].disposeCount, 1);

    sessions[1].complete();
    await tester.pumpAndSettle();
    expect(find.byType(VideoDetailsScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Third video'),
      ),
      findsOneWidget,
    );
    expect(sessions, hasLength(3));
    expect(sessions[1].disposeCount, 1);
    expect(sessions[2].disposeCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  _testPlayerWidget(
    'playlist dialog uses source membership and updates remotely',
    (tester) async {
      final client = _TestMissavClient(_details(), loggedIn: true)
        ..playlists = [
          const VideoLink(
            label: 'Fixture playlist',
            url: 'https://missav.ai/cn/playlists',
            kind: VideoLinkKind.playlist,
            sourceKey: 'playlist-key',
            isAdded: false,
          ),
        ];
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final session = _FakePlaybackSession();

      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.videoAddToPlaylist));
      await tester.pumpAndSettle();

      expect(client.playlistsCalls, 1);
      expect(find.text('Fixture playlist'), findsOneWidget);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(client.addedPlaylists, ['playlist-key']);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _videoDetailsLauncher({
  required VideoPlaybackSessionFactory sessionFactory,
}) => Builder(
  builder: (context) => Scaffold(
    body: TextButton(
      onPressed: () => unawaited(
        pushWorkDetailRoute(
          context,
          builder: (_) => _testVideoDetailsScreen(
            video: _video(),
            sessionFactory: sessionFactory,
          ),
        ),
      ),
      child: const Text('Open video'),
    ),
  ),
);

VideoDetailsScreen _testVideoDetailsScreen({
  Key? key,
  required VideoItem video,
  VideoDownloadTask? downloadedTask,
  VideoPlaybackSessionFactory? sessionFactory,
  VideoPlayerPlatform? platform,
  bool autoPlayVideo = false,
}) => VideoDetailsScreen(
  key: key,
  video: video,
  downloadedTask: downloadedTask,
  sessionFactory: sessionFactory,
  platformFactory: () => platform ?? _TestVideoPlayerPlatform(),
  autoPlayVideo: autoPlayVideo,
);

Future<void> _pumpStandalonePlayer(
  WidgetTester tester,
  _FakePlaybackSession session, {
  double width = 400,
  double height = 800,
  VideoPlayerPlatform? platform,
  bool bounded = false,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final library = await _testLibrary();
  final playerPlatform = platform ?? _TestVideoPlayerPlatform();
  var fullscreen = false;
  final playerKey = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: S.supportedLocales,
      localizationsDelegates: S.localizationsDelegates,
      theme: ThemeData(useMaterial3: true),
      home: StatefulBuilder(
        builder: (context, setState) => Scaffold(
          body: Builder(
            builder: (context) {
              final player = VideoPlaybackPanel(
                key: playerKey,
                videoId: 'dvd-1',
                library: library,
                title: 'Fixture video',
                streams: _details().streams,
                sessionFactory: () => session,
                platform: playerPlatform,
                onFullscreenChanged: (value) =>
                    setState(() => fullscreen = value),
              );
              if (fullscreen || bounded) return player;
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [player],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _loadPlayerScreenshotFonts() async {
  final fontsPath =
      '${File(Platform.resolvedExecutable).parent.parent.parent.path}/material_fonts';
  final fonts = Directory(fontsPath).listSync().whereType<File>();
  for (final font in const [
    (family: 'Roboto', fileName: 'roboto-regular.ttf'),
    (family: 'MaterialIcons', fileName: 'materialicons-regular.otf'),
  ]) {
    final bytes = fonts
        .singleWhere(
          (file) => file.uri.pathSegments.last.toLowerCase() == font.fileName,
        )
        .readAsBytesSync();
    await (FontLoader(
      font.family,
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
}

Future<void> _openSettings(WidgetTester tester) async {
  if (_responsiveSheet().evaluate().isNotEmpty) return;
  await tester.tap(find.byKey(const ValueKey('video-player-more-menu')));
  await tester.pumpAndSettle();
}

Future<void> _closeSettings(WidgetTester tester) async {
  final sheet = _responsiveSheet();
  if (sheet.evaluate().isEmpty) return;
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(sheet, findsNothing);
}

Finder _responsiveSheet() =>
    find.byKey(const ValueKey('responsive-sheet-surface'));

Future<void> _ensureMoreMenuItemVisible(
  WidgetTester tester,
  Finder target,
) async {
  final sheet = _responsiveSheet();
  final scrollable = find
      .descendant(of: sheet, matching: find.byType(Scrollable))
      .first;
  final sheetTarget = find.descendant(of: sheet, matching: target);
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    sheetTarget,
    tester.getRect(sheet).height / 3,
    scrollable: scrollable,
  );
  await tester.ensureVisible(sheetTarget);
  await tester.pumpAndSettle();
}

Future<void> _chooseSetting(WidgetTester tester, String label) async {
  final s = await S.delegate.load(const Locale('en'));
  final separator = label.indexOf(': ');
  final value = separator < 0 ? label : label.substring(separator + 2);
  if (label.startsWith('${s.videoQuality}: ')) {
    await _openSettings(tester);
    final qualityOption = find.descendant(
      of: _responsiveSheet(),
      matching: find.byTooltip(s.videoQuality),
    );
    await _ensureMoreMenuItemVisible(tester, find.byTooltip(s.videoQuality));
    await tester.tap(qualityOption);
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(
        of: find.text(value),
        matching: find.byType(PopupMenuItem<int>),
      ),
    );
  } else if (label.startsWith('${s.playbackSpeed}: ')) {
    await _closeSettings(tester);
    await tester.tap(find.byTooltip(s.playbackSpeed));
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(
        of: find.text(value.replaceAll('×', 'X')),
        matching: find.byType(PopupMenuItem<double>),
      ),
    );
  } else if (label.startsWith('${s.videoPlayerSubtitleTrack}: ')) {
    await _closeSettings(tester);
    await tester.tap(find.byTooltip(s.videoPlayerSubtitleTrack));
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(
        of: find.text(label),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
  } else {
    await _openSettings(tester);
    final setting = find.text(label);
    await _ensureMoreMenuItemVisible(tester, setting);
    await tester.tap(setting);
  }
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _doubleTap(WidgetTester tester, Finder target) async {
  final position = tester.getCenter(target);
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tapAt(position);
}

Future<void> _tapGestureSurface(WidgetTester tester, Finder surface) async {
  final rect = tester.getRect(surface);
  await tester.tapAt(Offset(rect.center.dx, rect.top + rect.height * .2));
}

class _TestNavigationAuth extends StateNotifier<AuthState>
    implements AuthNotifier {
  _TestNavigationAuth() : super(const AuthState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(
  _TestMissavClient client,
  VideoLibrary library,
  VideoDownloads downloads,
  Widget home, {
  double textScale = 1,
  ThemeData? theme,
  AudioTrack? audioTrack,
  AppNavigationController? appNavigationController,
}) => ProviderScope(
  overrides: [
    if (appNavigationController != null)
      authProvider.overrideWith((ref) => _TestNavigationAuth()),
    videoClientProvider.overrideWith((ref) => client),
    videoLibraryProvider.overrideWith((ref) => library),
    videoDownloadsProvider.overrideWith((ref) => downloads),
    currentTrackProvider.overrideWith((ref) => Stream.value(audioTrack)),
    if (audioTrack != null) ...[
      isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
      positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
      durationProvider.overrideWith(
        (ref) => Stream.value(const Duration(minutes: 4)),
      ),
      playerStateProvider.overrideWith(
        (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
      ),
      queueProvider.overrideWith((ref) => Stream.value([audioTrack])),
      manualSkipAvailabilityProvider.overrideWith(
        (ref) => Stream.value(ManualSkipAvailability.unavailable),
      ),
      lyricAutoLoaderProvider.overrideWith((ref) {}),
    ],
  ],
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
    theme: theme ?? ThemeData(useMaterial3: true),
    navigatorObservers: [
      if (appNavigationController != null) appNavigationController,
    ],
    builder: (context, child) {
      final navigation = appNavigationController;
      return MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: navigation == null
            ? child!
            : AppNavigationShell(controller: navigation, child: child!),
      );
    },
    home: home,
  ),
);

Future<VideoLibrary> _testLibrary({double? volume, Duration? position}) async {
  SharedPreferences.setMockInitialValues({
    if (volume != null) 'video_volume_v1': volume,
  });
  final library = VideoLibrary(
    preferences: await SharedPreferences.getInstance(),
  );
  await library.initialize();
  if (position != null) await library.savePosition('dvd-1', position);
  return library;
}

VideoItem _video() => const VideoItem(
  id: 'dvd-1',
  title: 'Fixture video',
  pageUrl: 'https://missav.ai/cn/dvd-1',
);

VideoDetails _details({
  bool isFavorite = false,
  String description = '',
  List<VideoLink> tags = const [],
}) => VideoDetails(
  video: _video(),
  description: description,
  tags: tags,
  streams: const [
    VideoStream(label: 'Auto', url: 'https://cdn.example/video.m3u8'),
    VideoStream(label: '720p', url: 'https://cdn.example/video-720.m3u8'),
  ],
  sourceId: 'source-id',
  isFavorite: isFavorite,
);

class _TestMissavClient extends MissavClient {
  _TestMissavClient(
    this.detailsResult, {
    this.loggedIn = false,
    this.initializeError,
  });

  VideoDetails detailsResult;
  VideoDetails? readyDetails;
  bool loggedIn;
  final Object? initializeError;
  String? _accountName;
  final List<bool> actorFavoriteChanges = [];
  final List<bool> videoFavoriteChanges = [];
  Future<void>? favoriteResponse;
  Completer<VideoDetails>? detailsCompleter;
  Completer<VideoDetails>? supplementCompleter;
  VideoDetails Function(VideoItem video)? detailsForVideo;
  int initializeCalls = 0;
  int detailsCalls = 0;
  int supplementCalls = 0;
  int playlistsCalls = 0;
  List<VideoLink> playlists = [];
  final List<String> addedPlaylists = [];
  final List<String> browsedUrls = [];
  int _generation = 0;

  @override
  int get sessionGeneration => _generation;

  void reconnect() {
    _generation++;
    detailsResult = VideoDetails(
      video: _video(),
      streams: const [
        VideoStream(label: 'Auto', url: 'http://127.0.0.1:1235/video.m3u8'),
      ],
    );
    notifyListeners();
  }

  @override
  String get homeUrl => 'https://missav.ai/cn';

  @override
  bool get isLoggedIn => loggedIn;

  @override
  String? get accountName => _accountName;

  void switchAccount({required bool isFavorite}) {
    loggedIn = true;
    _accountName = 'Account B';
    detailsResult = _details(isFavorite: isFavorite);
    notifyListeners();
  }

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (initializeError != null) throw initializeError!;
  }

  @override
  Future<VideoCatalogPage> browse(
    String url, {
    CancelToken? cancelToken,
    void Function(VideoCatalogPage page)? onParsed,
  }) async {
    browsedUrls.add(url);
    final page = VideoCatalogPage(title: url, url: url);
    onParsed?.call(page);
    return page;
  }

  @override
  Future<VideoDetails> details(
    VideoItem item, {
    FutureOr<void> Function(VideoDetails)? onReady,
  }) async {
    detailsCalls++;
    if (readyDetails case final preview?) await onReady?.call(preview);
    final completer = detailsCompleter;
    if (completer != null) return completer.future;
    return detailsForVideo?.call(item) ?? detailsResult;
  }

  @override
  Future<VideoDetails> supplementDetails(
    VideoDetails details, {
    FutureOr<void> Function(VideoDetails)? onReady,
  }) async {
    supplementCalls++;
    return supplementCompleter?.future ?? Future.value(detailsResult);
  }

  @override
  Future<List<VideoLink>> playlistsFor(VideoItem item) async {
    playlistsCalls++;
    return playlists;
  }

  @override
  Future<void> addToPlaylist(VideoLink playlist, VideoItem item) async {
    addedPlaylists.add(playlist.sourceKey!);
  }

  @override
  Future<void> setActorFavorite(VideoLink actor, bool favorite) async {
    actorFavoriteChanges.add(favorite);
  }

  @override
  Future<void> setVideoFavorite(VideoDetails details, bool favorite) async {
    videoFavoriteChanges.add(favorite);
    await favoriteResponse;
  }
}

class _TestVideoDownloads extends VideoDownloads {
  _TestVideoDownloads({
    required super.client,
    required super.library,
    this.task,
  });

  VideoDownloadTask? task;
  VideoItem? lastAddedVideo;

  void completeDownload() {
    task = task!.copyWith(status: VideoDownloadStatus.completed, progress: 1);
    notifyListeners();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<VideoDownloadTask> add(VideoItem video, VideoStream stream) async {
    lastAddedVideo = video;
    return VideoDownloadTask(
      id: video.id,
      video: video,
      quality: stream.label,
      isHls: stream.url.endsWith('.m3u8'),
      status: VideoDownloadStatus.queued,
    );
  }

  @override
  VideoDownloadTask? forVideo(String videoId) =>
      task?.id == videoId ? task : null;

  @override
  List<VideoDownloadTask> get tasks => task == null ? const [] : [task!];
}

class _FakePlaybackSession implements VideoPlaybackSession {
  _FakePlaybackSession() {
    _testPlaybackSessions.add(this);
  }

  final ValueNotifier<VideoPlaybackSnapshot> _snapshot = ValueNotifier(
    const VideoPlaybackSnapshot(),
  );
  bool attached = false;
  int loadStreamCount = 0;
  int loadFileCount = 0;
  int playCount = 0;
  int pauseCount = 0;
  int disposeCount = 0;
  int seekCount = 0;
  int surfaceMountCount = 0;
  int surfaceDisposeCount = 0;
  Duration lastPosition = Duration.zero;
  double lastVolume = 0;
  double lastRate = 1;
  final List<double> rateChanges = [];
  final List<Duration> requestedPositions = [];
  String? localPath;
  String? lastStreamUrl;
  Completer<void>? nextLoadCompleter;
  Completer<void>? nextRateCompleter;
  Object? nextLoadError;
  bool resetPositionOnError = false;
  String? selectedAudioTrack;
  String? selectedSubtitleTrack;
  final Completer<void> disposed = Completer<void>();

  void emitError(String error) {
    _snapshot.value = _snapshot.value.copyWith(error: error, buffering: true);
  }

  void complete() {
    _snapshot.value = _snapshot.value.copyWith(completed: true, playing: false);
  }

  void emitSnapshot({
    bool? playing,
    bool? buffering,
    Duration? bufferPosition,
    List<VideoPlaybackTrack>? audioTracks,
    String? selectedAudioTrackId,
    List<VideoPlaybackTrack>? subtitleTracks,
  }) {
    _snapshot.value = _snapshot.value.copyWith(
      playing: playing,
      buffering: buffering,
      bufferPosition: bufferPosition,
      audioTracks: audioTracks,
      selectedAudioTrackId: selectedAudioTrackId,
      subtitleTracks: subtitleTracks,
    );
  }

  @override
  ValueListenable<VideoPlaybackSnapshot> get snapshot {
    attached = true;
    return _snapshot;
  }

  @override
  Widget buildSurface({required double aspectRatio}) =>
      _FakeVideoSurface(session: this);

  @override
  Future<void> loadStream(
    VideoStream stream, {
    required Duration position,
    required double volume,
  }) async {
    loadStreamCount++;
    requestedPositions.add(position);
    lastStreamUrl = stream.url;
    lastPosition = position;
    lastVolume = volume;
    _snapshot.value = _snapshot.value.copyWith(clearError: true);
    final loadCompleter = nextLoadCompleter;
    nextLoadCompleter = null;
    if (loadCompleter != null) await loadCompleter.future;
    final error = nextLoadError;
    nextLoadError = null;
    if (error != null) {
      if (resetPositionOnError) {
        _snapshot.value = _snapshot.value.copyWith(position: Duration.zero);
      }
      throw error;
    }
    _snapshot.value = _snapshot.value.copyWith(
      position: position,
      duration: const Duration(minutes: 3),
      clearError: true,
    );
  }

  @override
  Future<void> loadFile(
    String path, {
    required Duration position,
    required double volume,
  }) async {
    loadFileCount++;
    localPath = path;
    lastPosition = position;
    lastVolume = volume;
    _snapshot.value = _snapshot.value.copyWith(
      position: position,
      duration: const Duration(minutes: 3),
      clearError: true,
    );
  }

  @override
  Future<void> play() async {
    playCount++;
    _snapshot.value = _snapshot.value.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _snapshot.value = _snapshot.value.copyWith(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    seekCount++;
    lastPosition = position;
    _snapshot.value = _snapshot.value.copyWith(position: position);
  }

  @override
  Future<void> setRate(double rate) async {
    final rateCompleter = nextRateCompleter;
    nextRateCompleter = null;
    if (rateCompleter != null) await rateCompleter.future;
    rateChanges.add(rate);
    lastRate = rate;
    _snapshot.value = _snapshot.value.copyWith(rate: rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    lastVolume = volume;
  }

  @override
  Future<void> selectAudioTrack(String id) async {
    selectedAudioTrack = id;
    _snapshot.value = _snapshot.value.copyWith(selectedAudioTrackId: id);
  }

  @override
  Future<void> selectSubtitleTrack(String id) async {
    selectedSubtitleTrack = id;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    _snapshot.dispose();
    if (!disposed.isCompleted) disposed.complete();
  }
}

class _FakeVideoSurface extends StatefulWidget {
  const _FakeVideoSurface({required this.session});

  final _FakePlaybackSession session;

  @override
  State<_FakeVideoSurface> createState() => _FakeVideoSurfaceState();
}

class _FakeVideoSurfaceState extends State<_FakeVideoSurface> {
  @override
  void initState() {
    super.initState();
    widget.session.surfaceMountCount++;
  }

  @override
  void dispose() {
    widget.session.surfaceDisposeCount++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(
    key: ValueKey('fake-video-surface'),
    color: Colors.black,
  );
}

class _FakeAdvancedPlaybackSession extends _FakePlaybackSession
    implements VideoPlaybackAdvancedSession {
  _FakeAdvancedPlaybackSession({this.sourceAspectRatio = 16 / 9});

  final loopModes = <bool>[];

  @override
  VideoController get videoController => _FakeVideoController();

  @override
  final double sourceAspectRatio;

  @override
  VideoPlaybackInfo get playbackInfo => (
    resolution: null,
    videoCodec: null,
    frameRate: null,
    videoBitrate: null,
    audioCodec: null,
    audioFormat: null,
  );

  @override
  Widget buildConfiguredSurface({
    required double? aspectRatio,
    required BoxFit fit,
    required SubtitleViewConfiguration subtitleViewConfiguration,
  }) => ClipRect(
    child: FittedBox(
      fit: fit,
      child: SizedBox(
        width: (aspectRatio ?? sourceAspectRatio) * 100,
        height: 100,
        child: buildSurface(aspectRatio: aspectRatio ?? sourceAspectRatio),
      ),
    ),
  );

  @override
  Future<Uint8List?> takeScreenshot() async => null;

  @override
  Future<void> setLoopSingle(bool enabled) async {
    loopModes.add(enabled);
  }

  @override
  Future<void> setSubtitleOffset(double seconds) async {}

  @override
  Future<void> loadExternalSubtitle(
    String path, {
    required String title,
  }) async {}

  @override
  Future<void> setSuperResolution(VideoSuperResolution mode) async {}
}

class _FakeVideoController extends Fake implements VideoController {}

class _FakeDesktopPiPPlatform extends VideoPlayerPlatform {
  _FakeDesktopPiPPlatform({
    TargetPlatform platform = TargetPlatform.windows,
    this._initiallyInPip = true,
  }) : super(platform: platform);

  final bool _initiallyInPip;

  final ValueNotifier<bool> _pictureInPicture = ValueNotifier(false);
  int exitCount = 0;
  final nativeFullscreenChanges = <bool>[];
  bool nativeFullscreen = false;
  bool? _fullscreenBeforePictureInPicture;
  Completer<void>? nextFullscreenCompleter;
  bool _disposed = false;

  @override
  ValueListenable<bool> get pictureInPicture => _pictureInPicture;

  @override
  bool get supportsPictureInPicture => true;

  @override
  Future<void> initialize() async {
    if (_initiallyInPip) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) _pictureInPicture.value = true;
      });
    }
  }

  void startPictureInPicture() {
    _fullscreenBeforePictureInPicture ??= nativeFullscreen;
    _pictureInPicture.value = true;
  }

  @override
  Future<void> exitPictureInPicture() async {
    exitCount++;
    _pictureInPicture.value = false;
    final fullscreen = _fullscreenBeforePictureInPicture;
    if (fullscreen != null) nativeFullscreen = fullscreen;
    _fullscreenBeforePictureInPicture = null;
  }

  @override
  Future<void> setNativeFullscreen(bool enabled) async {
    nativeFullscreenChanges.add(enabled);
    nativeFullscreen = enabled;
    if (enabled) {
      final transition = nextFullscreenCompleter;
      nextFullscreenCompleter = null;
      await transition?.future;
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _pictureInPicture.dispose();
  }
}

class _TestVideoPlayerPlatform extends VideoPlayerPlatform {
  final ValueNotifier<bool> _pictureInPicture = ValueNotifier(false);
  final List<bool> fullscreenStatusBarChanges = [];
  double brightness = 0.5;
  bool alwaysOnTop = false;
  Orientation? windowOrientation;
  Completer<void>? fullscreenStatusBarCompleter;

  @override
  Future<Orientation?> waitForWindowLayout() async => windowOrientation;

  @override
  ValueListenable<bool> get pictureInPicture => _pictureInPicture;

  @override
  bool get supportsBrightness => true;

  @override
  bool get supportsPictureInPicture => false;

  @override
  bool get supportsSystemBrightness => false;

  @override
  bool get supportsBatteryStatus => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isAlwaysOnTop() async => alwaysOnTop;

  @override
  Future<void> setAlwaysOnTop(bool enabled) async {
    alwaysOnTop = enabled;
  }

  @override
  Future<void> setNativeFullscreen(bool enabled) async {}

  @override
  Future<void> setFullscreenStatusBarHidden(bool hidden) async {
    fullscreenStatusBarChanges.add(hidden);
    if (hidden) await fullscreenStatusBarCompleter?.future;
  }

  @override
  Future<double> getBrightness() async => brightness;

  @override
  Future<void> setBrightness(double value) async {
    brightness = value;
  }

  @override
  Future<void> setKeepScreenOn(bool enabled) async {}

  @override
  Future<void> setBackgroundPlayback(bool enabled) async {}

  @override
  Future<void> setAutoPictureInPicture(
    bool enabled, {
    double aspectRatio = 16 / 9,
  }) async {}

  @override
  Future<void> setGravityOrientation(bool enabled) async {}

  @override
  Future<void> dispose() async {
    _pictureInPicture.dispose();
  }
}

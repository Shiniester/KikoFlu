import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
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
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      expect(session.pauseCount, 0);
      expect(session.snapshot.value.playing, isTrue);

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
      expect(session.playCount, 0);
      expect(layoutRect.size, const Size(376, 211.5));
      expect(controlsRect.top, greaterThanOrEqualTo(layoutRect.top));
      expect(controlsRect.left, greaterThanOrEqualTo(layoutRect.left));
      expect(controlsRect.right, lessThanOrEqualTo(layoutRect.right));
      expect(controlsRect.bottom, lessThanOrEqualTo(layoutRect.bottom));
      expect(controlsRect.height, lessThanOrEqualTo(112));
      expect(find.byKey(const ValueKey('video-volume-slider')), findsNothing);

      await expectLater(
        layout,
        matchesGoldenFile('goldens/video_playback_compact_paused.png'),
      );

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

  _testPlayerWidget(
    'more menu tracks the inline viewport across resize and keeps fullscreen height',
    (tester) async {
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);
      final layout = find.byKey(const ValueKey('video-playback-layout'));
      final l10n = await S.delegate.load(const Locale('en'));

      await _openSettings(tester);
      final sheet = _responsiveSheet();
      final portraitViewportHeight = tester.getSize(layout).height;
      expect(
        tester.getRect(sheet).height,
        lessThanOrEqualTo(portraitViewportHeight),
      );
      expect(tester.getRect(sheet).bottom, closeTo(800, .1));

      tester.view.physicalSize = const Size(1200, 800);
      await tester.pumpAndSettle();
      final landscapeViewportHeight = tester.getSize(layout).height;
      expect(landscapeViewportHeight, greaterThan(portraitViewportHeight));
      expect(tester.getRect(sheet).height, greaterThan(portraitViewportHeight));
      expect(
        tester.getRect(sheet).height,
        lessThanOrEqualTo(landscapeViewportHeight),
      );
      expect(tester.getRect(sheet).right, closeTo(1200, .1));

      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(sheet).height,
        lessThanOrEqualTo(tester.getSize(layout).height),
      );
      expect(tester.getRect(sheet).bottom, closeTo(800, .1));

      await _closeSettings(tester);
      await tester.tap(find.byTooltip(l10n.videoFullscreen));
      await tester.pumpAndSettle();
      await _openSettings(tester);
      expect(
        tester.getRect(sheet).height,
        greaterThan(tester.getSize(layout).height),
      );
      expect(tester.getRect(sheet).height, lessThanOrEqualTo(800));
    },
  );

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
    'fullscreen surface is replaced while desktop PiP is active',
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

      platform.startPictureInPicture();
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey('video-fullscreen-placeholder'),
          skipOffstage: false,
        ),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey('fake-video-surface'), skipOffstage: false),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);

      await platform.exitPictureInPicture();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('video-fullscreen-placeholder')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);
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
    await _openSettings(tester);

    final layout = find.byKey(const ValueKey('video-playback-layout'));
    final sheet = _responsiveSheet();
    final portraitViewportHeight = tester.getSize(layout).height;
    expect(
      tester.getRect(sheet).height,
      lessThanOrEqualTo(portraitViewportHeight),
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
    expect(
      tester.getRect(sheet).height,
      lessThanOrEqualTo(landscapeViewportHeight),
    );
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
      expect(Navigator.of(tester.element(videoSurface)).canPop(), isTrue);

      await fullscreenDuringLongPress.up();
      await tester.pumpAndSettle();
      expect(session.lastRate, 1.5);
      expect(session.snapshot.value.playing, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(Navigator.of(tester.element(videoSurface)).canPop(), isFalse);
    },
  );

  _testPlayerWidget(
    'two-finger pinch zoom can be restored to the original view',
    (tester) async {
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);
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
      expect(tester.takeException(), isNull);
    },
  );

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
      expect(Navigator.of(tester.element(videoSurface)).canPop(), isTrue);
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
      expect(Navigator.of(tester.element(fullscreenControl)).canPop(), isTrue);
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
      await tester.tap(find.byTooltip('Fixture actor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.videoFavoriteActor));
      await tester.pumpAndSettle();

      expect(client.actorFavoriteChanges, [true]);
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
    final client = _TestMissavClient(
      _details(),
      initializeError: StateError('Secure storage unavailable'),
    );
    final library = await _testLibrary();
    final task = VideoDownloadTask(
      id: 'dvd-1',
      video: _video(),
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
  bool autoPlayVideo = false,
}) => VideoDetailsScreen(
  key: key,
  video: video,
  downloadedTask: downloadedTask,
  sessionFactory: sessionFactory,
  platformFactory: _TestVideoPlayerPlatform.new,
  autoPlayVideo: autoPlayVideo,
);

Future<void> _pumpStandalonePlayer(
  WidgetTester tester,
  _FakePlaybackSession session, {
  double width = 400,
  double height = 800,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final library = await _testLibrary();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: S.supportedLocales,
      localizationsDelegates: S.localizationsDelegates,
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: VideoPlaybackPanel(
          videoId: 'dvd-1',
          library: library,
          title: 'Fixture video',
          streams: _details().streams,
          sessionFactory: () => session,
          platform: _TestVideoPlayerPlatform(),
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
  final list = find
      .descendant(of: sheet, matching: find.byType(ListView))
      .first;
  final scrollable = find
      .descendant(of: list, matching: find.byType(Scrollable))
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

Widget _app(
  _TestMissavClient client,
  VideoLibrary library,
  VideoDownloads downloads,
  Widget home, {
  double textScale = 1,
  ThemeData? theme,
}) => ProviderScope(
  overrides: [
    videoClientProvider.overrideWith((ref) => client),
    videoLibraryProvider.overrideWith((ref) => library),
    videoDownloadsProvider.overrideWith((ref) => downloads),
    currentTrackProvider.overrideWith((ref) => Stream.value(null)),
  ],
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
    theme: theme ?? ThemeData(useMaterial3: true),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
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

VideoDetails _details({bool isFavorite = false}) => VideoDetails(
  video: _video(),
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
  Widget buildSurface({required double aspectRatio}) => const ColoredBox(
    key: ValueKey('fake-video-surface'),
    color: Colors.black,
  );

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

  void startPictureInPicture() => _pictureInPicture.value = true;

  @override
  Future<void> exitPictureInPicture() async {
    exitCount++;
    _pictureInPicture.value = false;
  }

  @override
  Future<void> setNativeFullscreen(bool enabled) async {
    nativeFullscreenChanges.add(enabled);
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
  double brightness = 0.5;
  bool alwaysOnTop = false;

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

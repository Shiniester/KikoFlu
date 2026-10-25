import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_details_screen.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_download_task.dart';
import 'package:kikoeru_flutter/src/videos/video_downloads.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';

import '../support/linux_golden_file_comparator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final defaultGoldenFileComparator = goldenFileComparator;
  setUpAll(() {
    if (Platform.isLinux) {
      goldenFileComparator = LinuxTolerantGoldenFileComparator(
        Uri.parse('test/videos/video_playback_test.dart'),
      );
    }
  });
  tearDownAll(() => goldenFileComparator = defaultGoldenFileComparator);

  testWidgets('detail route waits for entry animation to settle', (
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

    await tester.pumpAndSettle();
    expect(client.detailsCalls, 1);
    expect(sessionCreations, 1);
    expect(session.loadStreamCount, 1);
  });

  testWidgets('detail route ignores a late result during pop', (tester) async {
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

  testWidgets(
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

  testWidgets(
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
      await tester.pumpAndSettle();

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
      expect(session.disposeCount, 1);
    },
  );

  testWidgets('video playback starts paused and keeps its own volume', (
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
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
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

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
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

  testWidgets('paused details player keeps compact controls on its surface', (
    tester,
  ) async {
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
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
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
    expect(controlsRect.height, lessThanOrEqualTo(72));
    expect(find.byKey(const ValueKey('video-volume-slider')), findsNothing);

    await expectLater(
      layout,
      matchesGoldenFile('goldens/video_playback_compact_paused.png'),
    );

    await tester.tap(find.byKey(const ValueKey('video-gesture-surface')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('video-controls')))
          .opacity,
      0,
    );
  });

  testWidgets('paused and buffering playback controls can be hidden', (
    tester,
  ) async {
    final session = _FakePlaybackSession();
    await _pumpStandalonePlayer(tester, session);
    final surface = find.byKey(const ValueKey('video-gesture-surface'));
    final controls = find.byKey(const ValueKey('video-controls'));
    final l10n = await S.delegate.load(const Locale('en'));

    await tester.tap(surface);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
    await tester.tap(surface);
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

    await tester.tap(surface);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);
    await tester.tap(surface);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
  });

  testWidgets(
    'playback settings keep quality, audio, subtitle and rate actions',
    (tester) async {
      final session = _FakePlaybackSession();
      await _pumpStandalonePlayer(tester, session);
      session.emitSnapshot(
        audioTracks: const [
          VideoPlaybackTrack(id: 'audio-en', label: 'English'),
          VideoPlaybackTrack(id: 'audio-ja', label: 'Japanese'),
        ],
        subtitleTracks: const [
          VideoPlaybackTrack(id: 'subtitle-en', label: 'English'),
        ],
      );
      await tester.pump();
      final l10n = await S.delegate.load(const Locale('en'));

      await _chooseSetting(tester, '${l10n.audioFormatPreference}: Japanese');
      expect(session.selectedAudioTrack, 'audio-ja');
      await _chooseSetting(tester, '${l10n.videoSubtitle}: English');
      expect(session.selectedSubtitleTrack, 'subtitle-en');
      await _chooseSetting(tester, '${l10n.videoQuality}: 720p');
      expect(session.loadStreamCount, 2);
      await _chooseSetting(tester, '${l10n.playbackSpeed}: 1.25×');
      expect(session.lastRate, 1.25);
    },
  );

  testWidgets('double tap toggles playback and controls hide and return', (
    tester,
  ) async {
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
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('video-controls')))
          .opacity,
      0,
    );

    final rect = tester.getRect(surface);
    await tester.dragFrom(
      Offset(rect.center.dx, rect.top + 10),
      Offset(rect.width * .1, 0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('video-controls')))
          .opacity,
      1,
    );
    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('video-position-slider')))
          .value,
      12000,
    );

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('video-controls')))
          .opacity,
      0,
    );

    await tester.tap(surface);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('video-controls')))
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
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('video-controls')))
          .opacity,
      1,
    );

    await _doubleTap(tester, surface);
    await tester.pumpAndSettle();
    expect(session.pauseCount, 1);
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('video-controls')))
          .opacity,
      1,
    );
  });

  testWidgets('controls stay visible during volume and popup interaction', (
    tester,
  ) async {
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
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('video-controls')))
          .opacity,
      1,
    );

    await volumeGesture.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('video-controls')))
          .opacity,
      1,
    );

    final surfaceRect = tester.getRect(
      find.byKey(const ValueKey('video-gesture-surface')),
    );
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('video-controls')))
          .opacity,
      0,
    );
    await tester.tapAt(Offset(surfaceRect.center.dx, surfaceRect.top + 10));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    await _openSettings(tester);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('video-controls')))
          .opacity,
      1,
    );

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const ValueKey('video-controls')))
          .opacity,
      0,
    );
  });

  testWidgets('surface and slider seek once on release and clamp to duration', (
    tester,
  ) async {
    final session = _FakePlaybackSession();
    await _pumpStandalonePlayer(tester, session);
    final surface = find.byKey(const ValueKey('video-gesture-surface'));
    final rect = tester.getRect(surface);

    await tester.dragFrom(
      Offset(rect.left + rect.width * .1, rect.top + 10),
      Offset(rect.width * .1, 0),
    );
    await tester.pump();
    expect(session.seekCount, 1);
    expect(session.lastPosition, const Duration(seconds: 12));

    await tester.dragFrom(
      Offset(rect.left + rect.width * .7, rect.top + 10),
      Offset(rect.width * .1, 0),
    );
    await tester.pump();
    expect(session.seekCount, 2);
    expect(session.lastPosition, const Duration(seconds: 24));

    await tester.dragFrom(
      Offset(rect.left + rect.width * .5, rect.top + 10),
      Offset(rect.width * 2, 0),
    );
    await tester.pump();
    expect(session.seekCount, 3);
    expect(session.lastPosition, const Duration(minutes: 3));

    final cancelled = await tester.startGesture(
      Offset(rect.left + rect.width * .4, rect.top + 10),
      kind: PointerDeviceKind.touch,
    );
    await cancelled.moveTo(Offset(rect.left + rect.width * .6, rect.top + 10));
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
  });

  testWidgets(
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
      expect(session.rateChanges, [1.5, 2, 1.5]);
      expect(session.lastRate, 1.5);

      final backgrounded = await tester.startGesture(
        center,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(session.lastRate, 2);
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
      expect(session.lastRate, 2);
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

  testWidgets(
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
      expect(session.lastPosition, const Duration(seconds: 5));

      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
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

  testWidgets('fullscreen volume control updates while playback is paused', (
    tester,
  ) async {
    final client = _TestMissavClient(_details());
    final library = await _testLibrary(volume: 37);
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
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
  });

  testWidgets('fullscreen quality loading and errors remain visible paused', (
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
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.videoFullscreen));
    await tester.pumpAndSettle();

    final loading = Completer<void>();
    session.nextLoadCompleter = loading;
    await _openSettings(tester);
    final qualityItem = find.text('${l10n.videoQuality}: 720p');
    await tester.ensureVisible(qualityItem);
    await tester.pump();
    await tester.tapAt(tester.getCenter(qualityItem));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(session.loadStreamCount, 2);
    expect(session.lastStreamUrl, 'https://cdn.example/video-720.m3u8');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('video-playback-loading')),
      findsOneWidget,
    );
    loading.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-playback-loading')), findsNothing);

    session.nextLoadError = StateError('Fixture stream error');
    await _chooseSetting(tester, '${l10n.videoQuality}: Auto');
    expect(find.text(l10n.videoPlaybackFailed), findsOneWidget);
    expect(find.byKey(const ValueKey('video-playback-loading')), findsNothing);
    expect(session.playCount, 0);
  });

  testWidgets('player errors replace loading while an open is pending', (
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
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
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

  testWidgets('fullscreen playback recovery stays usable on a narrow screen', (
    tester,
  ) async {
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
            library: library,
            streams: _details().streams,
            sessionFactory: () => session,
            onVerifyAccess: () async {
              callbackSawFullscreenRoute = navigatorKey.currentState!.canPop();
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
  });

  for (final failFirstRequest in [false, true]) {
    testWidgets(
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
            VideoDetailsScreen(video: _video(), sessionFactory: () => session),
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

  testWidgets('account change clears and reloads detail favorite state', (
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
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bookmark_outline), findsOneWidget);

    client.switchAccount(isFavorite: true);
    await tester.pumpAndSettle();

    expect(client.detailsCalls, 2);
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
  });

  testWidgets('actor menu sends the selected favorite state to the source', (
    tester,
  ) async {
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
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip('Fixture actor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.videoFavoriteActor));
    await tester.pumpAndSettle();

    expect(client.actorFavoriteChanges, [true]);
  });

  testWidgets('a new media session reloads the stream for the same account', (
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
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();
    client.reconnect();
    await tester.pumpAndSettle();
    expect(client.isLoggedIn, isFalse);
    expect(client.detailsCalls, 2);
    expect(session.loadStreamCount, 2);
    expect(session.lastStreamUrl, 'http://127.0.0.1:1235/video.m3u8');
  });

  testWidgets('covering or backgrounding the detail pauses without resuming', (
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
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
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
  });

  testWidgets('finishing a download keeps playback until details reopen', (
    tester,
  ) async {
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
                  builder: (_) => VideoDetailsScreen(
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

    await tester.pageBack();
    await tester.pumpAndSettle();
    session = _FakePlaybackSession();
    await tester.tap(find.text('Open video'));
    await tester.pumpAndSettle();
    expect(session.loadFileCount, 1);
    expect(session.localPath, downloads.task!.localPath);
    expect(session.loadStreamCount, 0);
    expect(session.lastPosition, const Duration(seconds: 44));
    expect(client.detailsCalls, 1);
  });

  testWidgets('downloaded details skip online detail loading', (tester) async {
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
        VideoDetailsScreen(
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

  testWidgets('downloads keep metadata returned with the parsed details', (
    tester,
  ) async {
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
    final client = _TestMissavClient(
      VideoDetails(video: parsedVideo, streams: _details().streams),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.download));
    await tester.pumpAndSettle();

    expect(identical(downloads.lastAddedVideo, parsedVideo), isTrue);
    expect(downloads.lastAddedVideo?.releaseDate, '2025-01-02');
    expect(downloads.lastAddedVideo?.actors.single.label, 'Parsed actor');
    expect(downloads.lastAddedVideo?.tags.single.label, 'Parsed tag');
    expect(downloads.lastAddedVideo?.hasSubtitles, isTrue);
    expect(downloads.lastAddedVideo?.isUncensored, isTrue);
  });

  testWidgets('detail layout fits 360px and 1280px windows at 1.3 text scale', (
    tester,
  ) async {
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
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
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
  });

  testWidgets('playlist dialog uses source membership and updates remotely', (
    tester,
  ) async {
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
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
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
  });
}

Widget _videoDetailsLauncher({
  required VideoPlaybackSessionFactory sessionFactory,
}) => Builder(
  builder: (context) => Scaffold(
    body: TextButton(
      onPressed: () => unawaited(
        pushWorkDetailRoute(
          context,
          builder: (_) => VideoDetailsScreen(
            video: _video(),
            sessionFactory: sessionFactory,
          ),
        ),
      ),
      child: const Text('Open video'),
    ),
  ),
);

Future<void> _pumpStandalonePlayer(
  WidgetTester tester,
  _FakePlaybackSession session, {
  double width = 400,
}) async {
  tester.view.physicalSize = Size(width, 800);
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
          streams: _details().streams,
          sessionFactory: () => session,
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
  await tester.tap(find.byKey(const ValueKey('video-settings-menu')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _chooseSetting(WidgetTester tester, String label) async {
  await _openSettings(tester);
  final setting = find.text(label);
  await tester.ensureVisible(setting);
  await tester.pump();
  await tester.tapAt(tester.getCenter(setting));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _doubleTap(WidgetTester tester, Finder target) async {
  final position = tester.getCenter(target);
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tapAt(position);
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
  bool loggedIn;
  final Object? initializeError;
  String? _accountName;
  final List<bool> actorFavoriteChanges = [];
  final List<bool> videoFavoriteChanges = [];
  Future<void>? favoriteResponse;
  Completer<VideoDetails>? detailsCompleter;
  int initializeCalls = 0;
  int detailsCalls = 0;
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
  Future<VideoDetails> details(VideoItem item) async {
    detailsCalls++;
    final completer = detailsCompleter;
    if (completer != null) return completer.future;
    return detailsResult;
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
  final ValueNotifier<VideoPlaybackSnapshot> _snapshot = ValueNotifier(
    const VideoPlaybackSnapshot(),
  );
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
  String? localPath;
  String? lastStreamUrl;
  Completer<void>? nextLoadCompleter;
  Completer<void>? nextRateCompleter;
  Object? nextLoadError;
  String? selectedAudioTrack;
  String? selectedSubtitleTrack;

  void emitError(String error) {
    _snapshot.value = _snapshot.value.copyWith(error: error, buffering: true);
  }

  void emitSnapshot({
    bool? playing,
    bool? buffering,
    List<VideoPlaybackTrack>? audioTracks,
    List<VideoPlaybackTrack>? subtitleTracks,
  }) {
    _snapshot.value = _snapshot.value.copyWith(
      playing: playing,
      buffering: buffering,
      audioTracks: audioTracks,
      subtitleTracks: subtitleTracks,
    );
  }

  @override
  ValueListenable<VideoPlaybackSnapshot> get snapshot => _snapshot;

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
    lastStreamUrl = stream.url;
    lastPosition = position;
    lastVolume = volume;
    final loadCompleter = nextLoadCompleter;
    nextLoadCompleter = null;
    if (loadCompleter != null) await loadCompleter.future;
    final error = nextLoadError;
    nextLoadError = null;
    if (error != null) throw error;
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
  }

  @override
  Future<void> selectSubtitleTrack(String id) async {
    selectedSubtitleTrack = id;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    _snapshot.dispose();
  }
}

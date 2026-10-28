import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_player_platform.dart';
import 'package:kikoeru_flutter/src/videos/video_super_resolution.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const fixturePath = String.fromEnvironment('KIKOFLU_TEST_VIDEO');

  testWidgets(
    'native player switches inline, fullscreen and picture-in-picture',
    (tester) async {
      MediaKit.ensureInitialized();
      if (Platform.isWindows) await windowManager.ensureInitialized();
      // Keep the four-second fixture alive during native window transitions.
      SharedPreferences.setMockInitialValues({
        'video_player_v1_repeat_mode': 1,
      });
      final file = File(fixturePath);
      final library = VideoLibrary();
      await library.initialize();
      expect(
        await file.exists(),
        isTrue,
        reason: 'Install the local video fixture before running the test',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final player = Player();
      final session = MediaKitVideoPlaybackSession(player: player);
      final platform = VideoPlayerPlatform();
      final playerKey = GlobalKey();
      var fullscreen = false;
      try {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: StatefulBuilder(
              builder: (context, setState) {
                final panel = VideoPlaybackPanel(
                  key: playerKey,
                  videoId: 'parity-fixture',
                  title: '视频播放',
                  library: library,
                  localPath: file.path,
                  initialVolume: 0,
                  platform: platform,
                  sessionFactory: () => session,
                  onFullscreenChanged: (value) {
                    if (context.mounted) {
                      setState(() => fullscreen = value);
                    }
                  },
                );
                return Scaffold(
                  appBar: fullscreen ? null : AppBar(title: const Text('视频详情')),
                  bottomNavigationBar: fullscreen
                      ? null
                      : const SizedBox(
                          height: 48,
                          child: Center(child: Text('音声播放条')),
                        ),
                  body: SafeArea(
                    top: !fullscreen,
                    bottom: !fullscreen,
                    child: fullscreen
                        ? panel
                        : SingleChildScrollView(child: panel),
                  ),
                );
              },
            ),
          ),
        );
        await _wait(tester, () => player.state.width != null);
        await session.play();
        await _wait(
          tester,
          () => player.state.position > const Duration(milliseconds: 500),
        );
        await session.videoController.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 20),
        );
        await session.pause();
        await tester.pumpAndSettle();
        expect(session.snapshot.value.error, isNull);
        final frame = await session.takeScreenshot();
        expect(frame, isNotNull);
        expect(frame, isNotEmpty);
        await File(
          '${Directory.systemTemp.path}/kikoflu-video-player-frame.png',
        ).writeAsBytes(frame!);
        if (find
            .byKey(const ValueKey('video-player-more-menu'))
            .evaluate()
            .isEmpty) {
          await tester.tap(find.byKey(const ValueKey('video-gesture-surface')));
          await tester.pumpAndSettle();
        }
        expect(
          find.byKey(const ValueKey('video-player-more-menu')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('video-position-slider')),
          findsOneWidget,
        );
        await tester.pumpAndSettle();

        final inlineSurface = tester.state(find.byType(Video));
        final detailsRoute = ModalRoute.of(tester.element(find.byType(Video)));
        await tester.ensureVisible(
          find.byKey(const ValueKey('video-fullscreen-control')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('video-fullscreen-control')),
        );
        await _wait(tester, () => fullscreen);
        await tester.pumpAndSettle();
        expect(detailsRoute?.isCurrent, isTrue);
        expect(find.text('视频详情'), findsNothing);
        expect(find.text('音声播放条'), findsNothing);
        expect(tester.state(find.byType(Video)), same(inlineSurface));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _wait(tester, () => !fullscreen);
        await tester.pumpAndSettle();
        expect(detailsRoute?.isCurrent, isTrue);
        expect(find.text('视频详情'), findsOneWidget);
        expect(find.text('音声播放条'), findsOneWidget);
        expect(tester.state(find.byType(Video)), same(inlineSurface));
        expect(player.state.playing, isFalse);

        await session.play();
        await tester.tap(find.byKey(const ValueKey('video-player-more-menu')));
        await _wait(tester, () {
          final sheets = find.byType(BottomSheet);
          return sheets.evaluate().isNotEmpty &&
              ModalRoute.of(tester.element(sheets.last))?.animation?.status ==
                  AnimationStatus.completed;
        });
        await tester.scrollUntilVisible(
          find.text('画中画'),
          150,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.text('画中画'));
        await _wait(tester, () => find.text('视频详情').evaluate().isEmpty);
        expect(find.text('音声播放条'), findsNothing);
        expect(player.state.playing, isTrue);
        await platform.exitPictureInPicture();
        await _wait(tester, () => find.text('视频详情').evaluate().isNotEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await session.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        library.dispose();
      }
    },
    skip: fixturePath.isEmpty || (!Platform.isAndroid && !Platform.isWindows),
  );

  testWidgets(
    'native picture-in-picture keeps the same video session playing',
    (tester) async {
      MediaKit.ensureInitialized();
      if (Platform.isWindows) await windowManager.ensureInitialized();
      final file = File(fixturePath);
      expect(
        await file.exists(),
        isTrue,
        reason: 'Install the local video fixture before running the test',
      );
      final player = Player();
      final controller = VideoController(player);
      final platform = VideoPlayerPlatform();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Video(
                controller: controller,
                controls: NoVideoControls,
                wakelock: false,
                pauseUponEnteringBackgroundMode: false,
                resumeUponEnteringForegroundMode: false,
              ),
            ),
          ),
        );
        await platform.initialize();
        expect(platform.supportsPictureInPicture, isTrue);
        final wasFullscreen = Platform.isWindows
            ? await windowManager.isFullScreen()
            : false;
        final wasAlwaysOnTop = Platform.isWindows
            ? await windowManager.isAlwaysOnTop()
            : false;
        final originalBounds = Platform.isWindows
            ? await windowManager.getBounds()
            : null;
        if (Platform.isWindows) {
          await platform.setNativeFullscreen(true);
          expect(await windowManager.isFullScreen(), isTrue);
          await platform.setNativeFullscreen(false);
          expect(await windowManager.isFullScreen(), wasFullscreen);
        }
        await platform.attachVideoController(controller);
        await player.open(Media(file.path), play: false);
        await player.setPlaylistMode(PlaylistMode.single);
        await player.setVolume(0);
        await player.play();
        await _wait(
          tester,
          () => player.state.position > const Duration(milliseconds: 500),
        );
        if (supportsVideoSuperResolution) {
          final native = player.platform as NativePlayer;
          await applyVideoSuperResolution(
            player,
            VideoSuperResolution.efficiency,
          );
          expect(
            await native.getProperty('glsl-shaders'),
            contains('Anime4K_Restore_CNN_M.glsl'),
          );
          await _verifyShaderPasses(tester, native, 'efficiency');
          await applyVideoSuperResolution(player, VideoSuperResolution.quality);
          expect(
            await native.getProperty('glsl-shaders'),
            contains('Anime4K_Restore_CNN_VL.glsl'),
          );
          await _verifyShaderPasses(tester, native, 'quality');
          await applyVideoSuperResolution(player, VideoSuperResolution.off);
          expect(await native.getProperty('glsl-shaders'), isEmpty);
          await player.seek(Duration.zero);
          await _wait(
            tester,
            () => player.state.position < const Duration(milliseconds: 500),
          );
        }
        await platform.setBackgroundPlayback(true);
        final position = player.state.position;
        if (Platform.isWindows) await platform.setNativeFullscreen(true);
        expect(
          await platform.enterPictureInPicture(controller, aspectRatio: 16 / 9),
          isTrue,
        );
        await _wait(tester, () => platform.pictureInPicture.value);
        if (Platform.isWindows) {
          expect(await windowManager.isFullScreen(), isFalse);
          expect(await windowManager.isAlwaysOnTop(), isTrue);
          final size = await windowManager.getSize();
          expect(size.width, closeTo(480, 2));
          expect(size.height, closeTo(270, 2));
        }
        await _wait(
          tester,
          () =>
              player.state.position >
              position + const Duration(milliseconds: 500),
        );
        expect(player.state.playing, isTrue);
        await platform.exitPictureInPicture();
        await _wait(tester, () => !platform.pictureInPicture.value);
        if (Platform.isWindows) {
          expect(await windowManager.isFullScreen(), isTrue);
          expect(await windowManager.isAlwaysOnTop(), wasAlwaysOnTop);
          await platform.setNativeFullscreen(false);
          expect(await windowManager.isFullScreen(), wasFullscreen);
          if (!wasFullscreen) {
            final bounds = await windowManager.getBounds();
            expect(
              (bounds.topLeft - originalBounds!.topLeft).distance,
              lessThanOrEqualTo(2),
            );
            expect(bounds.width, closeTo(originalBounds.width, 2));
            expect(bounds.height, closeTo(originalBounds.height, 2));
          }
        }
        await player.pause();
        await platform.setBackgroundPlayback(false);
        expect(tester.takeException(), isNull);
      } finally {
        await platform.dispose();
        await player.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    skip: fixturePath.isEmpty || (!Platform.isAndroid && !Platform.isWindows),
  );

  testWidgets(
    'external subtitles survive reload and selection through the track menu',
    (tester) async {
      MediaKit.ensureInitialized();
      expect(
        await File(fixturePath).exists(),
        isTrue,
        reason: 'Install the local video fixture before running the test',
      );
      final directory = await Directory.systemTemp.createTemp(
        'kikoflu_video_subtitles_',
      );
      final separator = Platform.isWindows ? ';' : ':';
      final subtitle = File('${directory.path}/字幕${separator}fixture.srt');
      await subtitle.writeAsString(
        '1\n00:00:00,000 --> 00:01:00,000\nParity external subtitle\n',
      );
      final player = Player();
      final session = MediaKitVideoPlaybackSession(player: player);
      final playbackErrors = <String>[];
      final errorSubscription = player.stream.error.listen(playbackErrors.add);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: session.buildSurface(aspectRatio: 16 / 9)),
          ),
        );
        await session.setLoopSingle(true);
        final native = player.platform as NativePlayer;
        await session.loadFile(
          fixturePath,
          position: const Duration(seconds: 1),
          volume: 0,
        );
        await session.play();
        await _wait(
          tester,
          () => player.state.position > const Duration(milliseconds: 1200),
        );
        await session.pause();
        await session.selectSubtitleTrack('no');
        expect(await native.getProperty('options/sid'), 'no');
        await session.selectSubtitleTrack('auto');
        expect(await native.getProperty('options/sid'), 'auto');
        await session.loadExternalSubtitle(subtitle.path, title: 'Fixture');
        await session.play();
        await _waitForSubtitle(tester, native, playbackErrors);
        await session.loadFile(
          fixturePath,
          position: const Duration(seconds: 1),
          volume: 0,
        );
        await session.play();
        await _waitForSubtitle(tester, native, playbackErrors);
        await session.selectSubtitleTrack('no');
        await session.loadFile(
          fixturePath,
          position: const Duration(seconds: 1),
          volume: 0,
        );
        await _wait(
          tester,
          () async => (await native.getProperty('time-pos')).isNotEmpty,
        );
        expect(await native.getProperty('sid'), 'no');
        await _wait(
          tester,
          () => player.state.tracks.subtitle.any(
            (track) => track.id != 'auto' && track.id != 'no',
          ),
        );
        final alternateSubtitle = File('${directory.path}/alternate.srt');
        await alternateSubtitle.writeAsString(
          '1\n00:00:00,000 --> 00:01:00,000\nAlternate external subtitle\n',
        );
        await session.loadExternalSubtitle(
          alternateSubtitle.path,
          title: 'Alternate',
        );
        await session.play();
        await _waitForSubtitle(
          tester,
          native,
          playbackErrors,
          expectedText: 'Alternate external subtitle',
        );
        await _wait(
          tester,
          () =>
              player.state.tracks.subtitle
                  .where((track) => track.id != 'auto' && track.id != 'no')
                  .length ==
              2,
        );
        await session.selectSubtitleTrack('no');
        final subtitleTrack = player.state.tracks.subtitle.firstWhere(
          (track) => track.id != 'auto' && track.id != 'no',
        );
        await session.selectSubtitleTrack(subtitleTrack.id);
        await session.play();
        await _waitForSubtitle(tester, native, playbackErrors);
        await session.loadFile(
          fixturePath,
          position: const Duration(seconds: 1),
          volume: 0,
        );
        await session.play();
        await _waitForSubtitle(tester, native, playbackErrors);
        if (supportsVideoSuperResolution) {
          final enabling = session.setSuperResolution(
            VideoSuperResolution.efficiency,
          );
          final disabling = session.setSuperResolution(
            VideoSuperResolution.off,
          );
          await Future.wait([enabling, disabling]);
          expect(await native.getProperty('glsl-shaders'), isEmpty);
        }
        expect(playbackErrors, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await errorSubscription.cancel();
        await tester.pumpWidget(const SizedBox.shrink());
        await session.dispose();
        expect(
          await directory.parent.resolveSymbolicLinks(),
          await Directory.systemTemp.resolveSymbolicLinks(),
        );
        await directory.delete(recursive: true);
      }
    },
    skip: fixturePath.isEmpty || (!Platform.isAndroid && !Platform.isWindows),
  );
}

Future<void> _wait(WidgetTester tester, FutureOr<bool> Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!await ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Native video state timed out');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _verifyShaderPasses(
  WidgetTester tester,
  NativePlayer native,
  String preset,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (true) {
    await tester.pump(const Duration(milliseconds: 100));
    final passes = await native.getProperty('vo-passes');
    if (passes.isEmpty) {
      debugPrint('VIDEO_SHADER preset=$preset renderPassIntrospection=false');
      return;
    }
    final expectedPass = preset == 'quality'
        ? 'Anime4K-v4.0-Restore-CNN-(VL)'
        : 'Anime4K-v4.0-Restore-CNN-(M)';
    if (passes.contains(expectedPass)) {
      debugPrint(
        'VIDEO_SHADER preset=$preset renderPassIntrospection=true active=true',
      );
      return;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('Anime4K shader was configured but no render pass became active');
    }
  }
}

Future<void> _waitForSubtitle(
  WidgetTester tester,
  NativePlayer native,
  List<String> playbackErrors, {
  String expectedText = 'Parity external subtitle',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (true) {
    if ((await native.getProperty('sub-text')).contains(expectedText)) {
      return;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'External subtitle did not load: '
        'sid=${await native.getProperty('sid')}, '
        'text=${await native.getProperty('sub-text')}, '
        'position=${await native.getProperty('time-pos')}, '
        'tracks=${await native.getProperty('track-list')}, '
        'statePosition=${native.state.position}, '
        'stateDuration=${native.state.duration}, '
        'stateTracks=${native.state.tracks.subtitle.map((track) => track.id).toList()}, '
        'errors=$playbackErrors',
      );
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

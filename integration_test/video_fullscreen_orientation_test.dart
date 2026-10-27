import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_playback_settings.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const fixturePath = String.fromEnvironment('KIKOFLU_TEST_VIDEO');

  testWidgets(
    'native fullscreen restores OS orientation before revealing details',
    (tester) async {
      MediaKit.ensureInitialized();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await _wait(
        tester,
        () => binding.lifecycleState == AppLifecycleState.resumed,
      );
      final systemOrientation = MediaQueryData.fromView(
        tester.view,
      ).orientation;
      final fullscreenOrientation = systemOrientation == Orientation.portrait
          ? VideoFullscreenOrientation.horizontal
          : VideoFullscreenOrientation.vertical;
      SharedPreferences.setMockInitialValues({
        'video_player_v1_fullscreen_orientation': fullscreenOrientation.index,
        'video_player_v1_repeat_mode': VideoPlayerRepeatMode.single.index,
      });
      final file = File(fixturePath);
      expect(await file.exists(), isTrue);
      final library = VideoLibrary();
      await library.initialize();
      final player = Player();
      final session = MediaKitVideoPlaybackSession(player: player);
      final playerKey = GlobalKey();
      var fullscreen = false;
      var monitoring = false;
      final prematureDirections = <Orientation>[];
      const detailsKey = ValueKey('video-orientation-details');

      void checkFrame(Duration _) {
        if (!monitoring) return;
        final media = MediaQueryData.fromView(tester.view);
        final layout = find.byKey(const ValueKey('video-playback-layout'));
        if (fullscreen &&
            media.orientation == systemOrientation &&
            layout.evaluate().isNotEmpty &&
            tester.getRect(layout).height > media.size.height * .6) {
          prematureDirections.add(media.orientation);
        }
        final details = find.text('视频详情');
        final detailsVisible = details.evaluate().isNotEmpty;
        if (detailsVisible) {
          final detailsContext = details.evaluate().single;
          if (ModalRoute.of(detailsContext)?.isCurrent == true) {
            final orientation = MediaQuery.orientationOf(detailsContext);
            if (orientation != systemOrientation) {
              prematureDirections.add(orientation);
            }
          }
        }
        binding.addPostFrameCallback(checkFrame);
      }

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
                  videoId: 'orientation-fixture',
                  title: '视频播放',
                  library: library,
                  localPath: file.path,
                  initialVolume: 0,
                  sessionFactory: () => session,
                  onFullscreenChanged: (value) {
                    if (context.mounted) {
                      setState(() => fullscreen = value);
                    }
                  },
                );
                return Scaffold(
                  key: detailsKey,
                  appBar: fullscreen ? null : AppBar(title: const Text('视频详情')),
                  body: fullscreen
                      ? panel
                      : SingleChildScrollView(child: panel),
                );
              },
            ),
          ),
        );
        await _wait(tester, () => player.state.width != null);
        await session.pause();
        final position = player.state.position;
        await tester.pumpAndSettle();
        final inlineSurface = tester.state(find.byType(Video));
        final detailsRoute = ModalRoute.of(
          tester.element(find.byKey(detailsKey)),
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('video-fullscreen-control')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('video-fullscreen-control')),
        );
        await _wait(tester, () {
          return fullscreen &&
              MediaQueryData.fromView(tester.view).orientation !=
                  systemOrientation;
        });
        await tester.pumpAndSettle();
        expect(detailsRoute?.isCurrent, isTrue);
        expect(find.text('视频详情'), findsNothing);
        expect(tester.state(find.byType(Video)), same(inlineSurface));

        // Keep the device stationary so releasing the lock returns to its OS direction.
        monitoring = true;
        binding.addPostFrameCallback(checkFrame);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _wait(tester, () => !fullscreen);
        await tester.pumpAndSettle();
        monitoring = false;
        expect(prematureDirections, isEmpty);
        expect(detailsRoute?.isCurrent, isTrue);
        expect(find.text('视频详情'), findsOneWidget);
        expect(tester.state(find.byType(Video)), same(inlineSurface));
        expect(
          MediaQueryData.fromView(tester.view).orientation,
          systemOrientation,
        );
        expect(player.state.playing, isFalse);
        expect(player.state.position, position);
        expect(tester.takeException(), isNull);
      } finally {
        monitoring = false;
        await tester.pumpWidget(const SizedBox.shrink());
        await session.dispose();
        library.dispose();
        await SystemChrome.setPreferredOrientations(const []);
      }
    },
    skip: fixturePath.isEmpty || !Platform.isAndroid,
  );
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Native fullscreen orientation timed out');
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
}

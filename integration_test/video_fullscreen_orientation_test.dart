import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
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
      var monitoring = false;
      final prematureDirections = <Orientation>[];
      const detailsKey = ValueKey('video-orientation-details');

      void checkFrame(Duration _) {
        if (!monitoring) return;
        final details = find.byKey(detailsKey, skipOffstage: false);
        if (details.evaluate().isNotEmpty) {
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
            home: Scaffold(
              key: detailsKey,
              appBar: AppBar(title: const Text('视频详情')),
              body: VideoPlaybackPanel(
                videoId: 'orientation-fixture',
                title: '视频播放',
                library: library,
                localPath: file.path,
                initialVolume: 0,
                sessionFactory: () => session,
              ),
            ),
          ),
        );
        await _wait(tester, () => player.state.width != null);
        await session.pause();
        final position = player.state.position;
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('video-fullscreen-control')),
        );
        await _wait(tester, () {
          final details = tester.element(
            find.byKey(detailsKey, skipOffstage: false),
          );
          return ModalRoute.of(details)?.isCurrent == false &&
              MediaQueryData.fromView(tester.view).orientation !=
                  systemOrientation;
        });
        await tester.pumpAndSettle();

        // Keep the device stationary so releasing the lock returns to its OS direction.
        monitoring = true;
        binding.addPostFrameCallback(checkFrame);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _wait(tester, () {
          final details = tester.element(
            find.byKey(detailsKey, skipOffstage: false),
          );
          return ModalRoute.of(details)?.isCurrent == true &&
              find
                  .byKey(
                    const ValueKey('video-fullscreen-placeholder'),
                    skipOffstage: false,
                  )
                  .evaluate()
                  .isEmpty;
        });
        await tester.pumpAndSettle();
        monitoring = false;
        expect(prematureDirections, isEmpty);
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

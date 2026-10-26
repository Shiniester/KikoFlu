import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_settings_screen.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_settings_screen.dart';
import 'package:kikoeru_flutter/src/videos/video_playback_settings.dart';
import 'package:kikoeru_flutter/src/videos/video_super_resolution.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('playback preferences use PiliPlus defaults and persist', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final settings = VideoPlaybackSettings(preferences: preferences);
    await settings.initialize();

    expect(settings.doubleTapSeekSeconds, 10);
    expect(settings.longPressRate, 3);
    expect(settings.dynamicLongPressRate, isFalse);
    expect(settings.playbackRate, 1);
    expect(settings.speedList, VideoPlaybackSettings.defaultSpeedList);
    expect(settings.autoPlay, isFalse);
    expect(settings.autoFullscreen, isFalse);
    expect(settings.autoExitFullscreen, isTrue);
    expect(settings.autoPictureInPicture, isFalse);
    expect(settings.enableDoubleTapSeek, isTrue);
    expect(settings.enableSideSwipeAdjust, isTrue);
    expect(settings.enableFullscreenGesture, isTrue);
    expect(settings.relativeSwipeSeek, isFalse);
    expect(settings.swipeSeekDuration, 90);
    expect(settings.fit, VideoPlayerFit.contain);
    expect(settings.loopSingle, isFalse);
    expect(settings.backgroundPlayback, isFalse);
    expect(settings.extendedControlTime, isFalse);
    expect(settings.showFullscreenBattery, isTrue);
    expect(settings.subtitlesEnabled, isTrue);
    expect(settings.fullscreenOrientation, VideoFullscreenOrientation.auto);
    expect(settings.bottomProgressMode, VideoBottomProgressMode.always);

    await settings.setDoubleTapSeekSeconds(15);
    await settings.setLongPressRate(2.5);
    await settings.setDynamicLongPressRate(true);
    await settings.setAutoPlay(true);
    await settings.setAutoFullscreen(true);
    await settings.addSpeed(4);
    await settings.setPlaybackRate(4);
    await settings.removeSpeed(2);
    await settings.setShowFullscreenBattery(false);
    await settings.setAutoExitFullscreen(false);
    await settings.setAutoPictureInPicture(true);
    await settings.setEnableDoubleTapSeek(false);
    await settings.setEnableSideSwipeAdjust(false);
    await settings.setEnableFullscreenGesture(false);
    await settings.setRelativeSwipeSeek(true);
    await settings.setSwipeSeekDuration(50);
    await settings.setFit(VideoPlayerFit.cover);
    await settings.setFullscreenOrientation(
      VideoFullscreenOrientation.horizontal,
    );
    await settings.setBottomProgressMode(
      VideoBottomProgressMode.fullscreenOnly,
    );
    await settings.setLoopSingle(true);
    await settings.setBackgroundPlayback(true);
    await settings.setSubtitleFontSize(40);
    await settings.setSubtitleBackground(false);
    await settings.setSubtitleOffsetSeconds(1.2);
    await settings.setSubtitlesEnabled(false);
    settings.dispose();

    final restored = VideoPlaybackSettings(preferences: preferences);
    await restored.initialize();
    expect(restored.doubleTapSeekSeconds, 15);
    expect(restored.longPressRate, 2.5);
    expect(restored.dynamicLongPressRate, isTrue);
    expect(restored.autoPlay, isTrue);
    expect(restored.autoFullscreen, isTrue);
    expect(restored.speedList, [0.5, 0.75, 1, 1.25, 1.5, 1.75, 3, 4]);
    expect(restored.defaultSpeed, 4);
    expect(restored.showFullscreenBattery, isFalse);
    expect(restored.autoExitFullscreen, isFalse);
    expect(restored.autoPictureInPicture, isTrue);
    expect(restored.enableDoubleTapSeek, isFalse);
    expect(restored.enableSideSwipeAdjust, isFalse);
    expect(restored.enableFullscreenGesture, isFalse);
    expect(restored.relativeSwipeSeek, isTrue);
    expect(restored.swipeSeekDuration, 50);
    expect(restored.fit, VideoPlayerFit.cover);
    expect(
      restored.fullscreenOrientation,
      VideoFullscreenOrientation.horizontal,
    );
    expect(restored.bottomProgressMode, VideoBottomProgressMode.fullscreenOnly);
    expect(restored.loopSingle, isTrue);
    expect(restored.backgroundPlayback, isTrue);
    expect(restored.subtitleFontSize, 40);
    expect(restored.subtitleBackground, isFalse);
    expect(restored.subtitleOffsetSeconds, 1.2);
    expect(restored.subtitlesEnabled, isFalse);
    restored.dispose();
  });

  test(
    'related repeat mode persists when a related video list is available',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final settings = VideoPlaybackSettings(preferences: preferences);
      await settings.initialize();
      await settings.setRepeatMode(VideoPlayerRepeatMode.related);
      settings.dispose();

      final restored = VideoPlaybackSettings(preferences: preferences);
      await restored.initialize();
      expect(restored.repeatMode, VideoPlayerRepeatMode.related);
      restored.dispose();
    },
  );

  test(
    'reload sees settings changed by another player settings route',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final first = VideoPlaybackSettings(preferences: preferences);
      final second = VideoPlaybackSettings(preferences: preferences);
      await first.initialize();
      await second.initialize();

      await second.setAutoPlay(true);
      await first.reload();

      expect(first.autoPlay, isTrue);
      first.dispose();
      second.dispose();
    },
  );

  test('flip and super resolution stay scoped to one settings instance', () async {
    SharedPreferences.setMockInitialValues({
      'video_player_v1_flip_horizontal': true,
      'video_player_v1_flip_vertical': true,
      'video_player_v1_super_resolution': VideoSuperResolution.quality.index,
    });
    final preferences = await SharedPreferences.getInstance();
    final currentVideo = VideoPlaybackSettings(preferences: preferences);
    await currentVideo.initialize();

    expect(currentVideo.flipHorizontal, isFalse);
    expect(currentVideo.flipVertical, isFalse);
    expect(currentVideo.superResolution, VideoSuperResolution.off);

    await currentVideo.setFlipHorizontal(true);
    await currentVideo.setFlipVertical(true);
    await currentVideo.setSuperResolution(VideoSuperResolution.quality);
    await currentVideo.reload();

    expect(currentVideo.flipHorizontal, isTrue);
    expect(currentVideo.flipVertical, isTrue);
    expect(currentVideo.superResolution, VideoSuperResolution.quality);
    currentVideo.dispose();

    final nextVideo = VideoPlaybackSettings(preferences: preferences);
    await nextVideo.initialize();
    expect(nextVideo.flipHorizontal, isFalse);
    expect(nextVideo.flipVertical, isFalse);
    expect(nextVideo.superResolution, VideoSuperResolution.off);
    nextVideo.dispose();
  });

  testWidgets('playback settings update live and remain localized', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = VideoPlaybackSettings(
      preferences: await SharedPreferences.getInstance(),
    );
    await settings.initialize();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        home: VideoPlaybackSettingsScreen(settings: settings),
      ),
    );
    final l10n = await S.delegate.load(const Locale('en'));

    final backgroundSetting = find.text(l10n.videoPlayerBackgroundPlayback);
    await tester.scrollUntilVisible(
      backgroundSetting,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(backgroundSetting);
    await tester.pumpAndSettle();
    expect(settings.backgroundPlayback, isTrue);

    final seekDuration = find.text(l10n.videoPlayerDoubleTapSeekDuration);
    await tester.scrollUntilVisible(
      seekDuration,
      -240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(seekDuration);
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 s'));
    await tester.pumpAndSettle();
    expect(settings.doubleTapSeekSeconds, 15);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
  });

  testWidgets('narrow subtitle and orientation pickers fit large text', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = VideoPlaybackSettings(
      preferences: await SharedPreferences.getInstance(),
    );
    await settings.initialize();
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: VideoPlaybackSettingsScreen(
          settings: settings,
          supportsFullscreenOrientation: true,
          supportsGravityRotation: true,
        ),
      ),
    );
    final l10n = await S.delegate.load(const Locale('en'));

    final orientationSetting = find.text(l10n.videoPlayerFullscreenOrientation);
    await tester.scrollUntilVisible(
      orientationSetting,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(orientationSetting);
    await tester.pumpAndSettle();
    await tester.tap(orientationSetting);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
  });

  testWidgets('video settings opens the persistent playback settings page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.meteor.kikoeruflutter/video_player');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') {
        return {'brightness': false, 'pictureInPicture': false};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        home: VideoSettingsScreen(),
      ),
    );
    final l10n = await S.delegate.load(const Locale('en'));

    await tester.tap(find.text(l10n.videoPlayerSettings));
    await tester.pumpAndSettle();
    expect(find.text(l10n.videoPlayerAutoPlay), findsOneWidget);

    await tester.tap(find.text(l10n.videoPlayerAutoPlay));
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'video_player_v1_auto_play',
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('system brightness denial explains the required permission', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = VideoPlaybackSettings(
      preferences: await SharedPreferences.getInstance(),
    );
    await settings.initialize();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        home: VideoPlaybackSettingsScreen(
          settings: settings,
          supportsSystemBrightness: true,
          onSystemBrightnessChanged: (_) async => false,
        ),
      ),
    );
    final l10n = await S.delegate.load(const Locale('en'));
    final brightnessSetting = find.ancestor(
      of: find.text(l10n.videoPlayerSystemBrightness),
      matching: find.byType(SwitchListTile),
    );
    await tester.scrollUntilVisible(
      brightnessSetting,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(brightnessSetting);
    await tester.pumpAndSettle();

    expect(settings.systemBrightness, isFalse);
    expect(
      find.text(l10n.videoPlayerSystemBrightnessPermission),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
  });
}

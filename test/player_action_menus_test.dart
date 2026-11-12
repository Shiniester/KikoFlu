import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/floating_lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/native_audio_effects.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_controls_widget.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_info_panel.dart';
import 'package:kikoeru_flutter/src/widgets/player/playlist_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/responsive_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = AudioTrack(id: 'track', title: 'Track', url: 'audio.mp3');

Future<void> _openMenu(
  WidgetTester tester, {
  required bool infoPanel,
  required GlobalKey<NavigatorState> navigatorKey,
  VoidCallback? onQueuePressed,
  VoidCallback? onMarkPressed,
  String? currentProgress,
  ValueChanged<LoopMode>? onRepeatModeChanged,
  Future<void>? repeatCompletion,
  ValueChanged<Duration>? onSeekBackward,
  ValueChanged<double>? onVolumeChanged,
  ValueChanged<double>? onSpeedChanged,
  bool fakeFloatingLyric = false,
  bool openMenu = true,
  int visibleActionCount = 0,
  bool isLandscape = false,
  Size viewSize = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = viewSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (fakeFloatingLyric)
          floatingLyricEnabledProvider.overrideWith(
            (ref) => _TestFloatingLyricNotifier(ref),
          ),
        if (onRepeatModeChanged != null ||
            repeatCompletion != null ||
            onSeekBackward != null ||
            onVolumeChanged != null ||
            onSpeedChanged != null)
          audioPlayerControllerProvider.overrideWith(
            (ref) => _TestAudioController(
              ref,
              onRepeatModeChanged: onRepeatModeChanged,
              repeatCompletion: repeatCompletion,
              onSeekBackward: onSeekBackward,
              onVolumeChanged: onVolumeChanged,
              onSpeedChanged: onSpeedChanged,
            ),
          ),
        currentTrackProvider.overrideWith((ref) => Stream.value(_track)),
        positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
        durationProvider.overrideWith(
          (ref) => Stream.value(const Duration(minutes: 4)),
        ),
        playerStateProvider.overrideWith(
          (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
        ),
        queueProvider.overrideWith((ref) => Stream.value([_track])),
        audioEffectsStatusProvider.overrideWith(
          (ref) => Stream.value(AudioEffectsStatus.ready),
        ),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('en'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => infoPanel
                ? TextButton(
                    onPressed: () => showResponsiveBottomSheet<void>(
                      context: context,
                      builder: (_) => PlayerInfoPanel(
                        track: _track,
                        currentProgress: currentProgress,
                        onMarkPressed: onMarkPressed,
                        onDetailPressed: null,
                        onQueuePressed: onQueuePressed ?? () {},
                        onImmersiveLyrics: () {},
                        onLyricSettings: () {},
                        visibleActionCount: visibleActionCount,
                      ),
                    ),
                    child: const Text('Open information menu'),
                  )
                : PlayerControlsWidget(
                    isLandscape: isLandscape,
                    isSeekingManually: false,
                    seekValue: 0,
                    onSeekChanged: (_) {},
                    onSeekEnd: (_) {},
                    onMarkPressed: onMarkPressed,
                    currentProgress: currentProgress,
                    onQueuePressed: onQueuePressed,
                    showMoreButton: true,
                    visibleActionCount: visibleActionCount,
                  ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (openMenu) {
    await tester.tap(
      infoPanel
          ? find.text('Open information menu')
          : find.byIcon(Icons.more_horiz),
    );
    await tester.pumpAndSettle();
  }
}

class _TestFloatingLyricNotifier extends FloatingLyricEnabledNotifier {
  _TestFloatingLyricNotifier(super.ref);

  @override
  Future<void> toggle() async {
    state = !state;
  }
}

class _TestAudioController extends AudioPlayerController {
  _TestAudioController(
    Ref ref, {
    this.onRepeatModeChanged,
    this.repeatCompletion,
    this.onSeekBackward,
    this.onVolumeChanged,
    this.onSpeedChanged,
  }) : super(ref.read(audioPlayerServiceProvider), ref);

  final ValueChanged<LoopMode>? onRepeatModeChanged;
  final Future<void>? repeatCompletion;
  final ValueChanged<Duration>? onSeekBackward;
  final ValueChanged<double>? onVolumeChanged;
  final ValueChanged<double>? onSpeedChanged;

  @override
  Future<void> setRepeatMode(LoopMode mode) async {
    onRepeatModeChanged?.call(mode);
    final completion = repeatCompletion;
    if (completion != null) await completion;
    state = state.copyWith(repeatMode: mode);
  }

  @override
  Future<void> seekBackward(Duration duration) async {
    onSeekBackward?.call(duration);
  }

  @override
  Future<void> setVolume(double value) async {
    onVolumeChanged?.call(value);
    state = state.copyWith(volume: value);
  }

  @override
  Future<void> setSpeed(double value) async {
    onSpeedChanged?.call(value);
    state = state.copyWith(speed: value);
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'custom_download_path': Directory.systemTemp.path,
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets('controls menu opens the queue when no callback is provided', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await _openMenu(tester, infoPanel: false, navigatorKey: navigatorKey);
    final queue = find.text('Playback Queue');
    await tester.ensureVisible(queue);
    await tester.tap(queue);
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistDialog), findsOneWidget);
    expect(find.byType(ResponsiveBottomSheet), findsNothing);
  });

  testWidgets('direct speed button still opens its dialog', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('player_buttons_config', 'speed');
    await prefs.setString('player_buttons_config_desktop', 'speed');
    await _openMenu(
      tester,
      infoPanel: false,
      navigatorKey: GlobalKey<NavigatorState>(),
      visibleActionCount: 1,
      openMenu: false,
    );
    await tester.tap(find.byIcon(Icons.speed));
    await tester.pumpAndSettle();
    expect(find.byType(ResponsiveAlertDialog), findsOneWidget);
    expect(find.text('Playback Speed'), findsOneWidget);
  });

  for (final (viewSize, isLandscape) in [
    (const Size(320, 844), false),
    (const Size(390, 844), false),
    (const Size(844, 390), true),
  ]) {
    testWidgets('audio effects aligns with other controls at $viewSize', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      const order = 'playback_audio_effects,seek_backward';
      await prefs.setString('player_buttons_config', order);
      await prefs.setString('player_buttons_config_desktop', order);
      await _openMenu(
        tester,
        infoPanel: false,
        navigatorKey: GlobalKey<NavigatorState>(),
        visibleActionCount: 2,
        openMenu: false,
        isLandscape: isLandscape,
        viewSize: viewSize,
      );

      final effectsCenter = tester.getCenter(find.byIcon(Icons.equalizer));
      expect(
        effectsCenter.dy,
        tester.getCenter(find.byIcon(Icons.replay_10)).dy,
      );
      expect(
        effectsCenter.dy,
        tester.getCenter(find.byIcon(Icons.more_horiz)).dy,
      );
      await tester.tap(find.byIcon(Icons.equalizer));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const PageStorageKey('audio-effects-equalizer')),
        findsOneWidget,
      );
    });
  }

  for (final (viewSize, isLandscape) in [
    (const Size(390, 844), false),
    (const Size(844, 390), true),
  ]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'action icons align at $viewSize with text scale $textScale',
        (tester) async {
          final prefs = await SharedPreferences.getInstance();
          const order =
              'playback_audio_effects,seek_backward,speed,sleep_timer';
          await prefs.setString('player_buttons_config', order);
          await prefs.setString('player_buttons_config_desktop', order);
          await _openMenu(
            tester,
            infoPanel: false,
            navigatorKey: GlobalKey<NavigatorState>(),
            visibleActionCount: 4,
            openMenu: false,
            isLandscape: isLandscape,
            viewSize: viewSize,
            textScale: textScale,
            onSpeedChanged: (_) {},
          );

          void expectIconsAligned(IconData timerIcon) {
            final center = tester.getCenter(find.byIcon(Icons.equalizer)).dy;
            for (final icon in [Icons.replay_10, Icons.speed, timerIcon]) {
              expect(tester.getCenter(find.byIcon(icon)).dy, center);
            }
          }

          expectIconsAligned(Icons.timer_outlined);
          final container = ProviderScope.containerOf(
            tester.element(find.byType(PlayerControlsWidget)),
          );
          await container
              .read(audioPlayerControllerProvider.notifier)
              .setSpeed(1.5);
          final timer = container.read(sleepTimerProvider.notifier);
          timer.setTimer(const Duration(minutes: 90));
          await tester.pumpAndSettle();

          expectIconsAligned(Icons.timer);
          final timerText = find.text(
            container.read(sleepTimerProvider).formattedTime,
          );
          expect(
            tester.getTopLeft(find.text('1.5x')).dy,
            greaterThanOrEqualTo(
              tester.getBottomLeft(find.byIcon(Icons.speed)).dy,
            ),
          );
          expect(
            tester.getTopLeft(timerText).dy,
            greaterThanOrEqualTo(
              tester.getBottomLeft(find.byIcon(Icons.timer)).dy,
            ),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final (order, icons) in [
    (
      'playback_audio_effects,seek_forward,repeat,queue,detail',
      [Icons.forward_10, Icons.repeat, Icons.queue_music, Icons.info_outline],
    ),
    (
      'playback_audio_effects,volume,mark,subtitle_adjustment,floating_lyric',
      [
        Icons.volume_up,
        Icons.bookmark_border,
        Icons.tune,
        Icons.picture_in_picture_alt_outlined,
      ],
    ),
  ]) {
    for (final (viewSize, isLandscape) in [
      (const Size(390, 844), false),
      (const Size(844, 390), true),
    ]) {
      testWidgets('configured action icons align at $viewSize: $order', (
        tester,
      ) async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('player_buttons_config', order);
        await prefs.setString('player_buttons_config_desktop', order);
        await _openMenu(
          tester,
          infoPanel: false,
          navigatorKey: GlobalKey<NavigatorState>(),
          visibleActionCount: 5,
          openMenu: false,
          isLandscape: isLandscape,
          viewSize: viewSize,
          fakeFloatingLyric: true,
        );

        final center = tester.getCenter(find.byIcon(Icons.equalizer)).dy;
        for (final icon in icons) {
          expect(tester.getCenter(find.byIcon(icon)).dy, center);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final infoPanel in [false, true]) {
    final location = infoPanel ? 'information' : 'controls';

    testWidgets('$location menu preserves queue navigation', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      var calls = 0;
      bool? menuOpenDuringCallback;
      await _openMenu(
        tester,
        infoPanel: infoPanel,
        navigatorKey: navigatorKey,
        onQueuePressed: () {
          calls++;
          menuOpenDuringCallback = navigatorKey.currentState!.canPop();
        },
      );
      final queue = find.text('Playback Queue');
      await tester.ensureVisible(queue);
      await tester.tap(queue);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(menuOpenDuringCallback, infoPanel);
      expect(
        find.byType(ResponsiveBottomSheet),
        infoPanel ? findsOneWidget : findsNothing,
      );
    });

    testWidgets('$location menu preserves marked action behavior', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      var calls = 0;
      bool? menuOpenDuringCallback;
      await _openMenu(
        tester,
        infoPanel: infoPanel,
        navigatorKey: navigatorKey,
        currentProgress: 'listening',
        onMarkPressed: () {
          calls++;
          menuOpenDuringCallback = navigatorKey.currentState!.canPop();
        },
      );
      final mark = find
          .ancestor(of: find.text('Add Mark'), matching: find.byType(ListTile))
          .first;
      expect(tester.widget<ListTile>(mark).selected, infoPanel);
      expect(
        find.descendant(of: mark, matching: find.byIcon(Icons.bookmark)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: mark, matching: find.byIcon(Icons.check_circle)),
        infoPanel ? findsNothing : findsOneWidget,
      );
      await tester.ensureVisible(mark);
      await tester.tap(mark);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(menuOpenDuringCallback, infoPanel);
    });

    testWidgets('$location menu toggles floating subtitles in place', (
      tester,
    ) async {
      await _openMenu(
        tester,
        infoPanel: infoPanel,
        navigatorKey: GlobalKey<NavigatorState>(),
        fakeFloatingLyric: true,
      );
      final tile = find
          .ancestor(
            of: find.text('Floating Subtitle'),
            matching: find.byType(ListTile),
          )
          .first;
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(ResponsiveBottomSheet), findsOneWidget);
      if (infoPanel) {
        expect(tester.widget<ListTile>(tile).selected, isTrue);
      } else {
        final toggle = find.descendant(of: tile, matching: find.byType(Switch));
        expect(tester.widget<Switch>(toggle).value, isTrue);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(toggle).value, isFalse);
      }
    });

    testWidgets('$location menu preserves seek dispatch and navigation', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      Duration? seek;
      bool? seekMenuOpen;
      await _openMenu(
        tester,
        infoPanel: infoPanel,
        navigatorKey: navigatorKey,
        onSeekBackward: (duration) {
          seek = duration;
          seekMenuOpen = navigatorKey.currentState!.canPop();
        },
      );
      final backward = find.text('Backward 10s');
      await tester.ensureVisible(backward);
      await tester.tap(backward);
      await tester.pumpAndSettle();
      expect(seek, const Duration(seconds: 10));
      expect(seekMenuOpen, infoPanel);
      expect(
        find.byType(ResponsiveBottomSheet),
        infoPanel ? findsOneWidget : findsNothing,
      );
    });

    testWidgets('$location menu cycles repeat before closing', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      LoopMode? selected;
      bool? menuOpenDuringCallback;
      await _openMenu(
        tester,
        infoPanel: infoPanel,
        navigatorKey: navigatorKey,
        onRepeatModeChanged: (mode) {
          selected = mode;
          menuOpenDuringCallback = navigatorKey.currentState!.canPop();
        },
      );
      final repeat = find.text('Repeat Mode');
      await tester.ensureVisible(repeat);
      await tester.tap(repeat);
      await tester.pumpAndSettle();
      expect(selected, LoopMode.one);
      expect(menuOpenDuringCallback, isTrue);
      expect(
        find.byType(ResponsiveBottomSheet),
        infoPanel ? findsOneWidget : findsNothing,
      );
      if (infoPanel) {
        final tile = find.ancestor(of: repeat, matching: find.byType(ListTile));
        expect(tester.widget<ListTile>(tile).selected, isTrue);
      }
    });

    testWidgets('$location menu handles an unfinished repeat update', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final completion = Completer<void>();
      addTearDown(() {
        if (!completion.isCompleted) completion.complete();
      });
      await _openMenu(
        tester,
        infoPanel: infoPanel,
        navigatorKey: navigatorKey,
        repeatCompletion: completion.future,
      );
      final repeat = find.text('Repeat Mode');
      await tester.ensureVisible(repeat);
      await tester.tap(repeat);
      await tester.pumpAndSettle();
      expect(
        find.byType(ResponsiveBottomSheet),
        infoPanel ? findsOneWidget : findsNothing,
      );
      if (infoPanel) {
        final tile = find.ancestor(of: repeat, matching: find.byType(ListTile));
        expect(tester.widget<ListTile>(tile).selected, isFalse);
      }
      completion.complete();
      await tester.pumpAndSettle();
      if (infoPanel) {
        final tile = find.ancestor(of: repeat, matching: find.byType(ListTile));
        expect(tester.widget<ListTile>(tile).selected, isTrue);
      }
    });

    testWidgets('$location menu preserves volume and mark presentation', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      double? changedVolume;
      await _openMenu(
        tester,
        infoPanel: infoPanel,
        navigatorKey: navigatorKey,
        onVolumeChanged: (value) => changedVolume = value,
      );
      final mark = find
          .ancestor(of: find.text('Add Mark'), matching: find.byType(ListTile))
          .first;
      expect(tester.widget<ListTile>(mark).enabled, !infoPanel);
      final volume = find.text('Volume');
      await tester.ensureVisible(volume);
      if (infoPanel) {
        await tester.tap(volume);
        await tester.pumpAndSettle();
        expect(find.byType(ResponsiveAlertDialog), findsOneWidget);
        expect(find.byType(ResponsiveBottomSheet), findsOneWidget);
      } else {
        expect(
          find.descendant(
            of: find.byType(ResponsiveBottomSheet),
            matching: find.byType(Slider),
          ),
          findsOneWidget,
        );
        expect(find.byType(ResponsiveAlertDialog), findsNothing);
      }
      final slider = find.descendant(
        of: infoPanel
            ? find.byType(ResponsiveAlertDialog)
            : find.byType(ResponsiveBottomSheet),
        matching: find.byType(Slider),
      );
      await tester.ensureVisible(slider);
      await tester.drag(slider, const Offset(-40, 0));
      await tester.pumpAndSettle();
      expect(changedVolume, lessThan(1));
      expect(find.byType(ResponsiveBottomSheet), findsOneWidget);
    });

    testWidgets('$location speed dialog works after opening', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      double? changedSpeed;
      await _openMenu(
        tester,
        infoPanel: infoPanel,
        navigatorKey: navigatorKey,
        onSpeedChanged: (value) => changedSpeed = value,
      );
      final speed = find.text('Playback Speed');
      await tester.ensureVisible(speed);
      await tester.tap(speed);
      await tester.pumpAndSettle();
      expect(
        find.byType(ResponsiveBottomSheet),
        infoPanel ? findsOneWidget : findsNothing,
      );
      final dialog = find.byType(ResponsiveAlertDialog);
      expect(dialog, findsOneWidget);
      await tester.drag(
        find.descendant(of: dialog, matching: find.byType(Slider)),
        const Offset(40, 0),
      );
      await tester.pumpAndSettle();
      expect(changedSpeed, greaterThan(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('$location menu opens audio effects', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await _openMenu(tester, infoPanel: infoPanel, navigatorKey: navigatorKey);
      final effects = find.text('Playback audio effects');
      await tester.ensureVisible(effects);
      await tester.tap(effects);
      await tester.pumpAndSettle();
      expect(
        find.byType(ResponsiveBottomSheet),
        findsNWidgets(infoPanel ? 2 : 1),
      );
      expect(find.text('Equalizer'), findsWidgets);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(
        find.byType(ResponsiveBottomSheet),
        infoPanel ? findsOneWidget : findsNothing,
      );
    });
  }
}

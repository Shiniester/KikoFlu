import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/main.dart' as app;
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/performance/performance_recorder.dart';
import 'package:kikoeru_flutter/src/providers/artwork_theme_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
import 'package:kikoeru_flutter/src/services/background_work_scheduler.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/global_audio_player_wrapper.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_visual_palette.dart';
import 'package:path_provider/path_provider.dart';

// Run only under the separate debug application ID. Media state is a fixture;
// routes, artwork, rendering and platform initialization use production code.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('player palette follows route completion on Android', (
    tester,
  ) async {
    final recorder = PerformanceRecorder.instance..start(force: true);
    final checks = <String>[];
    app.main(const []);
    await _wait(tester, () => recorder.metric('firstInteractiveMs') != null);
    await BackgroundWorkScheduler.instance.whenIdle();
    await (await StorageService.getPrefs()).setBool(
      'lyric_hint_has_shown',
      true,
    );
    final cover = File(
      '${(await getTemporaryDirectory()).path}/palette-test.png',
    );
    final bytes = await rootBundle.load('assets/icons/app_icon_opaque.png');
    await cover.writeAsBytes(bytes.buffer.asUint8List());
    final track = AudioTrack(
      id: 'palette-device-test',
      title: '播放器打开动画测试',
      artist: 'KikoFlu Debug',
      url: 'file:///palette-test-unused.wav',
      artworkUrl: cover.uri.toString(),
    );
    final theme = ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        key: const ValueKey('palette-device-test'),
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(track)),
          themeArtworkDescriptorProvider.overrideWith((ref) => null),
          isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
          positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
          durationProvider.overrideWith(
            (ref) => Stream.value(const Duration(minutes: 4)),
          ),
          playerStateProvider.overrideWith(
            (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
          ),
          queueProvider.overrideWith((ref) => Stream.value([track])),
          lyricAutoLoaderProvider.overrideWith((ref) {}),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          theme: theme,
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const GlobalAudioPlayerWrapper.workDetails(
            child: Scaffold(body: Center(child: Text('播放器打开动画测试'))),
          ),
        ),
      ),
    );
    final launcher = find.byKey(const ValueKey('mini-player-upward-launcher'));
    await _wait(tester, () => launcher.evaluate().isNotEmpty);
    await tester.pump(const Duration(seconds: 1));
    recorder.resetRun();
    final refreshRate = await const MethodChannel(
      'com.meteor.kikoeruflutter/performance',
    ).invokeMethod<double>('getDisplayRefreshRate');
    recorder.setRefreshRate(refreshRate ?? tester.view.display.refreshRate);

    for (var i = 0; i < 3; i++) {
      recorder.beginScenario(i == 0 ? 'tapCold' : 'tapWarm$i');
      await tester.tap(launcher);
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byType(AudioPlayerScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      recorder.endScenario();
      navigator.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 600));
    }
    checks.add('tap opens and closes: 3 cycles');

    recorder.beginScenario('dragCancel');
    final cancel = await tester.startGesture(tester.getCenter(launcher));
    await cancel.moveBy(const Offset(0, -100));
    await tester.pump(const Duration(milliseconds: 700));
    await cancel.cancel();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(AudioPlayerScreen), findsNothing);
    expect(tester.takeException(), isNull);
    recorder.endScenario();
    checks.add('held drag cancels safely');

    recorder.beginScenario('dragHandoff');
    final drag = await tester.startGesture(tester.getCenter(launcher));
    for (var step = 0; step < 14; step++) {
      await drag.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final previewState = tester.state(find.byType(AudioPlayerScreen));
    final previewPagesState = tester.state(
      find.byKey(const ValueKey('compact-player-pages')),
    );
    await drag.up();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(AudioPlayerScreen), findsOneWidget);
    expect(tester.state(find.byType(AudioPlayerScreen)), same(previewState));
    expect(
      tester.state(find.byKey(const ValueKey('compact-player-pages'))),
      same(previewPagesState),
    );
    expect(tester.takeException(), isNull);
    recorder.endScenario();
    final closing = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('compact-header-dismiss-surface')),
      ),
    );
    await closing.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      find.byKey(const ValueKey('player-artwork-flight-frame')),
      findsOneWidget,
    );
    await closing.moveBy(const Offset(0, 220));
    await closing.up();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(AudioPlayerScreen), findsNothing);
    checks.add('upward drag preserves player and page State through handoff');
    checks.add('downward return to work details uses artwork Hero');

    final initial = PlayerVisualPalette.fromDominant(
      Colors.pink,
      brightness: theme.brightness,
      accent: theme.colorScheme.primary,
      onAccent: theme.colorScheme.onPrimary,
    );
    final resolved = PlayerVisualPalette.fromDominant(
      theme.colorScheme.primary,
      brightness: theme.brightness,
      accent: theme.colorScheme.primary,
      onAccent: theme.colorScheme.onPrimary,
    );
    final route = createAudioPlayerRoute<void>(
      initialPalette: initial,
      initialPaletteTrackId: track.id,
    );
    unawaited(navigator.currentState!.push(route));
    expect(route.beginVerticalOpenGesture(), isTrue);
    // Let the production Hero register its endpoints before driving progress.
    await tester.pump();
    await tester.pump();
    route.updateVerticalOpenGesture(distance: 400, extent: 800);
    await tester.pump(const Duration(milliseconds: 900));
    expect(_backgroundColors(tester), initial.backgroundGradient.colors);
    checks.add('palette remains frozen past 300ms at partial expansion');
    route.updateVerticalOpenGesture(distance: 800, extent: 800);
    await tester.pump(const Duration(milliseconds: 900));
    expect(_backgroundColors(tester), initial.backgroundGradient.colors);
    checks.add('palette remains frozen at full expansion while held');
    expect(
      await route.endVerticalOpenGesture(velocity: 0, extent: 800),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 350));
    expect(_backgroundColors(tester), resolved.backgroundGradient.colors);
    checks.add('palette resolves after gesture completion');
    navigator.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.byType(AudioPlayerScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
    binding.reportData = {
      'mode': 'debug',
      'entry': 'workDetails',
      'checks': checks,
      'run': recorder.createRun(run: 1),
    };
  });
}

List<Color> _backgroundColors(WidgetTester tester) {
  final background = find.byKey(const ValueKey('player-palette-background'));
  final containers = tester.widgetList<AnimatedContainer>(
    find.descendant(of: background, matching: find.byType(AnimatedContainer)),
  );
  return containers
      .map((widget) => (widget.decoration! as BoxDecoration).gradient)
      .whereType<LinearGradient>()
      .first
      .colors;
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Player startup timed out');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

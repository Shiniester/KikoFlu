import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';
import 'package:shared_preferences/shared_preferences.dart';

const track = AudioTrack(
  id: 'frames',
  title: 'Player transition',
  artist: 'Artist',
  url: 'https://example.invalid/audio.flac',
);

void main() {
  testWidgets('real player expansion keyframes match v4.4.16', (tester) async {
    await pumpPlayer(tester);
    await tester.tap(find.byKey(const ValueKey('mini-player-upward-launcher')));
    await tester.pump();
    await tester.pump(playerRouteTransitionDuration * (8 / 45));
    await frame(tester, 'expand_80');
    await tester.pump(playerRouteTransitionDuration * (2 / 9));
    await frame(tester, 'expand_180');
    await tester.pump(playerRouteTransitionDuration * (4 / 15));
    await frame(tester, 'expand_300');
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('compact-player-pages'))),
    );
    await gesture.moveBy(const Offset(-20, 0));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    await frame(tester, 'page_partial');
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('interactive open reversal and handoff match v4.4.16', (
    tester,
  ) async {
    await pumpPlayer(tester);
    final launcher = find.byKey(const ValueKey('mini-player-upward-launcher'));
    final gesture = await tester.startGesture(tester.getCenter(launcher));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await frame(tester, 'drag_120');
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    await frame(tester, 'drag_reverse');
    await gesture.cancel();
    await tester.pumpAndSettle();
    final opening = await tester.startGesture(tester.getCenter(launcher));
    for (var step = 0; step < 14; step++) {
      await opening.moveBy(const Offset(0, -16));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await opening.up();
    await tester.pump(const Duration(milliseconds: 16));
    await frame(tester, 'handoff');
    await tester.pumpAndSettle();
  });
}

Future<void> frame(WidgetTester tester, String name) async {
  await expectLater(
    find.byKey(const ValueKey('transition-frames-root')),
    matchesGoldenFile('goldens/player_route_$name.png'),
  );
  expect(tester.takeException(), isNull);
}

Future<void> pumpPlayer(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
  await StorageService.initCritical();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentTrackProvider.overrideWith((ref) => Stream.value(track)),
        isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
        positionProvider.overrideWith(
          (ref) => Stream.value(const Duration(seconds: 42)),
        ),
        durationProvider.overrideWith(
          (ref) => Stream.value(const Duration(minutes: 4)),
        ),
        playerStateProvider.overrideWith(
          (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
        ),
        queueProvider.overrideWith((ref) => Stream.value([track])),
        manualSkipAvailabilityProvider.overrideWith(
          (ref) => Stream.value(ManualSkipAvailability.unavailable),
        ),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
      ],
      child: RepaintBoundary(
        key: const ValueKey('transition-frames-root'),
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          theme: ThemeData.dark(useMaterial3: true),
          home: const Scaffold(
            body: Center(child: Text('Player')),
            bottomNavigationBar: MiniPlayer(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

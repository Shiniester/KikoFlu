import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('mini player upward drag opens the interruptible player route', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    const track = AudioTrack(
      id: 'mini-route-track',
      title: 'Mini route track',
      url: 'https://example.invalid/audio.mp3',
      artist: 'Artist',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(track)),
          isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
          positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
          durationProvider.overrideWith(
            (ref) => Stream.value(const Duration(minutes: 4)),
          ),
          playerStateProvider.overrideWith(
            (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
          ),
          queueProvider.overrideWith((ref) => Stream.value(const [track])),
          lyricAutoLoaderProvider.overrideWith((ref) {}),
        ],
        child: const MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: Center(child: Text('mini-route-host')),
            bottomNavigationBar: MiniPlayer(enableArtworkHero: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final launcher = find.byKey(const ValueKey('mini-player-upward-launcher'));
    final gesture = await tester.startGesture(tester.getCenter(launcher));
    for (var index = 0; index < 14; index++) {
      await gesture.moveBy(const Offset(0, -16));
      await tester.pump();
      if (index == 1) {
        expect(
          find.byType(AudioPlayerScreen, skipOffstage: false),
          findsOneWidget,
        );
      }
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(AudioPlayerScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('compact-player-layout')), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('compact-header-dismiss-surface')),
      const Offset(0, 240),
    );
    await tester.pumpAndSettle();
    expect(find.text('mini-route-host'), findsOneWidget);
    expect(find.byType(AudioPlayerScreen), findsNothing);
  });
}

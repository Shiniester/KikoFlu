import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _goldenTrack = AudioTrack(
  id: 'golden-track',
  title: 'A long immersive player title',
  url: 'https://example.invalid/audio.flac',
  artist: 'Voice actor',
  album: 'Album title',
);

void main() {
  setUp(
    () =>
        SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true}),
  );

  const cases = <({String name, Size size, ThemeMode themeMode})>[
    (
      name: 'compact_390x844_light',
      size: Size(390, 844),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'compact_boundary_839x720_light',
      size: Size(839, 720),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'wide_boundary_840x720_dark',
      size: Size(840, 720),
      themeMode: ThemeMode.dark,
    ),
    (
      name: 'wide_1280x720_light',
      size: Size(1280, 720),
      themeMode: ThemeMode.light,
    ),
  ];

  for (final goldenCase in cases) {
    testWidgets('player golden ${goldenCase.name}', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = goldenCase.size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentTrackProvider.overrideWith(
              (ref) => Stream.value(_goldenTrack),
            ),
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
            queueProvider.overrideWith(
              (ref) => Stream.value(const [_goldenTrack]),
            ),
            lyricAutoLoaderProvider.overrideWith((ref) {}),
          ],
          child: MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            darkTheme: ThemeData.dark(useMaterial3: true),
            themeMode: goldenCase.themeMode,
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: const RepaintBoundary(
              key: ValueKey('player-golden-root'),
              child: AudioPlayerScreen(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      await expectLater(
        find.byKey(const ValueKey('player-golden-root')),
        matchesGoldenFile('goldens/audio_player_${goldenCase.name}.png'),
      );
      expect(tester.takeException(), isNull);
    });
  }
}

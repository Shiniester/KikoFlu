import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_cover_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _goldenTrack = AudioTrack(
  id: 'golden-track',
  title: 'A long immersive player title',
  url: 'https://example.invalid/audio.flac',
  artist: 'Voice actor',
  album: 'Album title',
);

const _linuxRasterizationTolerance = 0.003;

class _LinuxTolerantGoldenFileComparator extends LocalFileComparator {
  _LinuxTolerantGoldenFileComparator(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    final passed =
        result.passed || result.diffPercent <= _linuxRasterizationTolerance;
    if (passed) {
      result.dispose();
      return true;
    }

    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

void main() {
  final defaultGoldenFileComparator = goldenFileComparator;

  setUpAll(() {
    if (Platform.isLinux) {
      goldenFileComparator = _LinuxTolerantGoldenFileComparator(
        Uri.parse('test/audio_player_golden_test.dart'),
      );
    }
  });
  tearDownAll(() => goldenFileComparator = defaultGoldenFileComparator);

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

  testWidgets('player cover transition midpoint golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 280);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const first = AudioTrack(
      id: 'golden-cover-first',
      title: 'First',
      url: 'first.mp3',
    );
    const second = AudioTrack(
      id: 'golden-cover-second',
      title: 'Second',
      url: 'second.mp3',
    );
    final firstProvider = MemoryImage(
      File('assets/icons/app_icon_opaque.png').readAsBytesSync(),
    );
    final secondProvider = MemoryImage(
      File('assets/icons/privacy_protection_sample.png').readAsBytesSync(),
    );
    final track = ValueNotifier<AudioTrack>(first);
    addTearDown(track.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: const ValueKey('player-cover-transition-golden'),
                child: SizedBox(
                  width: 320,
                  height: 240,
                  child: ValueListenableBuilder<AudioTrack>(
                    valueListenable: track,
                    builder: (context, value, _) => PlayerCoverWidget(
                      track: value,
                      animateTrackChanges: true,
                      imageProviderOverride: value.id == first.id
                          ? firstProvider
                          : secondProvider,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => precacheImage(
        secondProvider,
        tester.element(find.byType(PlayerCoverWidget)),
      ),
    );
    track.value = second;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    await expectLater(
      find.byKey(const ValueKey('player-cover-transition-golden')),
      matchesGoldenFile('goldens/player_cover_transition_midpoint.png'),
    );
    expect(tester.takeException(), isNull);
  });
}

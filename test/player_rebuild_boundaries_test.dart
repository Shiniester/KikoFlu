import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_controls_widget.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_seek_preview.dart';

void main() {
  testWidgets('seek preview stays local and resets to provider position', (
    tester,
  ) async {
    final positions = StreamController<Duration>.broadcast(sync: true);
    final durations = StreamController<Duration?>.broadcast(sync: true);
    final seekPreview = ValueNotifier<PlayerSeekPreview?>(null);
    addTearDown(positions.close);
    addTearDown(durations.close);
    addTearDown(seekPreview.dispose);
    var shellBuilds = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          positionProvider.overrideWith((ref) => positions.stream),
          durationProvider.overrideWith((ref) => durations.stream),
          isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                shellBuilds++;
                return PlayerProgressSection(
                  isSeekingManually: true,
                  seekValue: 0.8,
                  onSeekChanged: (_) {},
                  onSeekEnd: (_) {},
                  seekingPositionListenable: seekPreview,
                );
              },
            ),
          ),
        ),
      ),
    );
    durations.add(null);
    positions.add(Duration.zero);
    await tester.pump();

    final shellBeforePreview = shellBuilds;
    seekPreview.value = (
      isSeekingManually: true,
      seekValue: 0.65,
      position: Duration.zero,
    );
    await tester.pump();

    expect(shellBuilds, shellBeforePreview);
    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('player-progress-slider')))
          .value,
      closeTo(0.65, 0.001),
    );

    durations.add(const Duration(minutes: 10));
    positions.add(const Duration(seconds: 30));
    await tester.pump();
    final previewElapsed = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(PlayerProgressSection),
            matching: find.byType(Text),
          ),
        )
        .first
        .data;
    seekPreview.value = null;
    await tester.pump();

    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('player-progress-slider')))
          .value,
      closeTo(0.05, 0.001),
    );
    final resetElapsed = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(PlayerProgressSection),
            matching: find.byType(Text),
          ),
        )
        .first
        .data;
    expect(resetElapsed, isNot(previewElapsed));
  });

  testWidgets('position and play state rebuild only their player regions', (
    tester,
  ) async {
    final positions = StreamController<Duration>.broadcast(sync: true);
    final durations = StreamController<Duration?>.broadcast(sync: true);
    final playerStates = StreamController<PlayerState>.broadcast(sync: true);
    addTearDown(positions.close);
    addTearDown(durations.close);
    addTearDown(playerStates.close);
    var shellBuilds = 0;
    var progressBuilds = 0;
    var playButtonBuilds = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          positionProvider.overrideWith((ref) => positions.stream),
          durationProvider.overrideWith((ref) => durations.stream),
          playerStateProvider.overrideWith((ref) => playerStates.stream),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                shellBuilds++;
                return Column(
                  children: [
                    PlayerProgressSection(
                      isSeekingManually: false,
                      seekValue: 0,
                      onSeekChanged: (_) {},
                      onSeekEnd: (_) {},
                      debugOnBuild: () => progressBuilds++,
                    ),
                    PlayerPlayPauseButton(
                      buttonSize: 72,
                      iconSize: 36,
                      debugOnBuild: () => playButtonBuilds++,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    durations.add(const Duration(minutes: 10));
    positions.add(Duration.zero);
    playerStates.add(PlayerState(false, ProcessingState.ready));
    await tester.pump();
    final shellBeforePosition = shellBuilds;
    final progressBeforePosition = progressBuilds;
    final playBeforePosition = playButtonBuilds;

    positions.add(const Duration(seconds: 30));
    await tester.pump();

    expect(progressBuilds, greaterThan(progressBeforePosition));
    expect(playButtonBuilds, playBeforePosition);
    expect(shellBuilds, shellBeforePosition);

    final progressBeforePlay = progressBuilds;
    playerStates.add(PlayerState(true, ProcessingState.ready));
    await tester.pump();

    expect(playButtonBuilds, greaterThan(playBeforePosition));
    expect(progressBuilds, progressBeforePlay);
    expect(shellBuilds, shellBeforePosition);
  });
}

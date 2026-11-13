import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';

class _PlaybackService implements AudioPlayerService {
  final tracks = StreamController<AudioTrack?>.broadcast(sync: true);
  final positions = StreamController<Duration>.broadcast(sync: true);
  @override
  final ValueNotifier<PlaybackPositionState> playbackPosition = ValueNotifier((
    trackId: null,
    position: Duration.zero,
    pendingJump: null,
    previewPosition: null,
    confirmedJump: 0,
  ));
  AudioTrack? track;
  Duration currentPosition = Duration.zero;
  Duration? replayedPosition;
  Completer<void>? positionSubscribed;

  @override
  AudioTrack? get currentTrack => track;
  @override
  Stream<AudioTrack?> get currentTrackStream => tracks.stream;
  @override
  Duration get position => currentPosition;
  @override
  Stream<Duration> get positionStream => Stream.multi((sink) {
    final replay = replayedPosition;
    if (replay != null) sink.add(replay);
    final subscription = positions.stream.listen(sink.add);
    sink.onCancel = subscription.cancel;
    final ready = positionSubscribed;
    if (ready != null && !ready.isCompleted) ready.complete();
  }, isBroadcast: true);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lyrics extends LyricController {
  _Lyrics(super.ref, LyricState initialState)
    : super(initialState: initialState);

  void replace(LyricState value) => state = value;
}

void main() {
  test(
    'track switch publishes the new position before another position tick',
    () async {
      const oldTrack = AudioTrack(id: 'old', title: 'Old', url: 'old');
      const newTrack = AudioTrack(id: 'new', title: 'New', url: 'new');
      final service = _PlaybackService()
        ..track = oldTrack
        ..currentPosition = const Duration(seconds: 14);
      final container = ProviderContainer(
        overrides: [audioPlayerServiceProvider.overrideWithValue(service)],
      );
      addTearDown(() async {
        container.dispose();
        await service.tracks.close();
        await service.positions.close();
      });
      final reset = Completer<void>();
      container.listen(positionProvider, (_, next) {
        if (next.valueOrNull == Duration.zero && !reset.isCompleted) {
          reset.complete();
        }
      }, fireImmediately: true);
      expect(
        await container.read(positionProvider.future),
        const Duration(seconds: 14),
      );

      service.currentPosition = Duration.zero;
      service.track = newTrack;
      service.tracks.add(newTrack);
      await reset.future.timeout(const Duration(seconds: 2));
      expect(container.read(positionProvider).valueOrNull, Duration.zero);

      final resumed = Completer<void>();
      container.listen(positionProvider, (_, next) {
        if (next.valueOrNull == const Duration(seconds: 12) &&
            !resumed.isCompleted) {
          resumed.complete();
        }
      });
      service.currentPosition = const Duration(seconds: 12);
      service.track = oldTrack;
      service.tracks.add(oldTrack);
      await resumed.future.timeout(const Duration(seconds: 2));
      expect(
        container.read(positionProvider).valueOrNull,
        const Duration(seconds: 12),
      );
    },
  );

  test('new subtitles never highlight the old track position', () async {
    const oldTrack = AudioTrack(id: 'old', title: 'Old', url: 'old');
    const newTrack = AudioTrack(id: 'new', title: 'New', url: 'new');
    final service = _PlaybackService()
      ..track = oldTrack
      ..currentPosition = const Duration(seconds: 5);
    service.playbackPosition.value = (
      trackId: oldTrack.id,
      position: service.position,
      pendingJump: null,
      previewPosition: null,
      confirmedJump: 0,
    );
    late _Lyrics lyrics;
    final container = ProviderContainer(
      overrides: [
        audioPlayerServiceProvider.overrideWithValue(service),
        lyricControllerProvider.overrideWith(
          (ref) => lyrics = _Lyrics(
            ref,
            LyricState(
              trackKey: 'old',
              lyrics: [
                LyricLine(
                  startTime: Duration.zero,
                  endTime: const Duration(seconds: 10),
                  text: 'old',
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      service.playbackPosition.dispose();
      await service.tracks.close();
      await service.positions.close();
    });
    container.listen(currentLyricIndexProvider, (_, __) {});
    final newTrackPublished = Completer<void>();
    container.listen(currentTrackProvider, (_, next) {
      if (next.valueOrNull == newTrack && !newTrackPublished.isCompleted) {
        newTrackPublished.complete();
      }
    });
    await container.read(currentTrackProvider.future);
    await container.read(positionProvider.future);

    service.currentPosition = Duration.zero;
    service.track = newTrack;
    service.tracks.add(newTrack);
    await newTrackPublished.future.timeout(const Duration(seconds: 2));
    lyrics.replace(
      LyricState(
        trackKey: 'new',
        lyrics: [
          LyricLine(
            startTime: const Duration(seconds: 5),
            endTime: const Duration(seconds: 10),
            text: 'new',
          ),
        ],
      ),
    );
    expect(container.read(currentLyricIndexProvider), -1);
  });

  test('track switch does not replay the previous position', () async {
    const oldTrack = AudioTrack(id: 'old', title: 'Old', url: 'old');
    const newTrack = AudioTrack(id: 'new', title: 'New', url: 'new');
    final service = _PlaybackService()
      ..track = oldTrack
      ..currentPosition = const Duration(seconds: 14);
    final container = ProviderContainer(
      overrides: [audioPlayerServiceProvider.overrideWithValue(service)],
    );
    addTearDown(() async {
      container.dispose();
      await service.tracks.close();
      await service.positions.close();
    });
    final values = <Duration>[];
    final reset = Completer<void>();
    final advanced = Completer<void>();
    container.listen(positionProvider, (_, next) {
      final value = next.isLoading ? null : next.valueOrNull;
      if (value == null) return;
      values.add(value);
      if (value == Duration.zero && !reset.isCompleted) reset.complete();
      if (value == const Duration(seconds: 1) && !advanced.isCompleted) {
        advanced.complete();
      }
    }, fireImmediately: true);
    await container.read(currentTrackProvider.future);
    await container.read(positionProvider.future);
    service
      ..replayedPosition = const Duration(seconds: 14)
      ..positionSubscribed = Completer<void>()
      ..currentPosition = Duration.zero
      ..track = newTrack;
    service.tracks.add(newTrack);
    await reset.future.timeout(const Duration(seconds: 2));
    await service.positionSubscribed!.future.timeout(
      const Duration(seconds: 2),
    );
    service.currentPosition = const Duration(seconds: 1);
    service.positions.add(const Duration(seconds: 1));
    await advanced.future.timeout(const Duration(seconds: 2));
    final newTrackValues = values.skipWhile((value) => value != Duration.zero);
    expect(newTrackValues, isNot(contains(const Duration(seconds: 14))));
    expect(newTrackValues.last, const Duration(seconds: 1));
  });
}

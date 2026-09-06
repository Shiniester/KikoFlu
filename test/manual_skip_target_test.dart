import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';

void main() {
  group('resolveManualSkipTarget', () {
    test('returns no target for an empty or invalid queue', () {
      expect(
        resolveManualSkipTarget(
          queueLength: 0,
          currentIndex: 0,
          repeatMode: LoopMode.all,
          direction: ManualSkipDirection.next,
        ),
        isNull,
      );
      expect(
        resolveManualSkipTarget(
          queueLength: 3,
          currentIndex: -1,
          repeatMode: LoopMode.all,
          direction: ManualSkipDirection.previous,
        ),
        isNull,
      );
    });

    for (final repeatMode in [LoopMode.off, LoopMode.one]) {
      test('$repeatMode follows sequence boundaries', () {
        expect(
          resolveManualSkipTarget(
            queueLength: 3,
            currentIndex: 0,
            repeatMode: repeatMode,
            direction: ManualSkipDirection.previous,
          ),
          isNull,
        );
        expect(
          resolveManualSkipTarget(
            queueLength: 3,
            currentIndex: 1,
            repeatMode: repeatMode,
            direction: ManualSkipDirection.previous,
          ),
          0,
        );
        expect(
          resolveManualSkipTarget(
            queueLength: 3,
            currentIndex: 1,
            repeatMode: repeatMode,
            direction: ManualSkipDirection.next,
          ),
          2,
        );
        expect(
          resolveManualSkipTarget(
            queueLength: 3,
            currentIndex: 2,
            repeatMode: repeatMode,
            direction: ManualSkipDirection.next,
          ),
          isNull,
        );
      });
    }

    test('queue repeat wraps in both directions', () {
      expect(
        resolveManualSkipTarget(
          queueLength: 3,
          currentIndex: 0,
          repeatMode: LoopMode.all,
          direction: ManualSkipDirection.previous,
        ),
        2,
      );
      expect(
        resolveManualSkipTarget(
          queueLength: 3,
          currentIndex: 2,
          repeatMode: LoopMode.all,
          direction: ManualSkipDirection.next,
        ),
        0,
      );
    });

    test('queue repeat restarts a single-item queue', () {
      expect(
        resolveManualSkipTarget(
          queueLength: 1,
          currentIndex: 0,
          repeatMode: LoopMode.all,
          direction: ManualSkipDirection.previous,
        ),
        0,
      );
      expect(
        resolveManualSkipTarget(
          queueLength: 1,
          currentIndex: 0,
          repeatMode: LoopMode.all,
          direction: ManualSkipDirection.next,
        ),
        0,
      );
    });
  });
}

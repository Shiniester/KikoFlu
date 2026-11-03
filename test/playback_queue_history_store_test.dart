import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/services/playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'history survives a store recreation and preserves queue identity',
    () async {
      const first = PlaybackSessionSnapshot(
        queue: [
          AudioTrack(
            id: 'chapter-1',
            title: 'Chapter 1',
            url: 'https://example.com/work.m3u8?token=old',
            workId: 42,
            startTimeMs: 1000,
            endTimeMs: 9000,
          ),
          AudioTrack(
            id: 'chapter-2',
            title: 'Chapter 2',
            url: 'file:///tmp/chapter-2.aac',
            sourcePath: '/tmp/chapter-2.aac',
          ),
        ],
        currentIndex: 1,
        position: Duration(seconds: 17),
        ownerKey: 'https://example.com\nalice',
        markingQueueId: 'queue-a',
      );
      const secondOwner = PlaybackSessionSnapshot(
        queue: [
          AudioTrack(
            id: 'other-owner-track',
            title: 'Other owner',
            url: 'https://example.com/other.mp3',
          ),
        ],
        currentIndex: 0,
        position: Duration.zero,
        ownerKey: 'https://example.com\nbob',
        markingQueueId: 'queue-b',
      );

      await const SharedPreferencesPlaybackQueueHistoryStore().save([
        first,
        secondOwner,
      ]);
      final restored = await const SharedPreferencesPlaybackQueueHistoryStore()
          .load();

      expect(restored, hasLength(2));
      expect(restored.first.queue, first.queue);
      expect(restored.first.currentIndex, first.currentIndex);
      expect(restored.first.position, first.position);
      expect(restored.first.ownerKey, first.ownerKey);
      expect(restored.first.markingQueueId, first.markingQueueId);
      expect(restored.first.queue.first.startTimeMs, 1000);
      expect(restored.last.ownerKey, secondOwner.ownerKey);
    },
  );

  test('an invalid history entry does not discard other owners', () async {
    const valid = PlaybackSessionSnapshot(
      queue: [
        AudioTrack(
          id: 'kept',
          title: 'Kept',
          url: 'https://example.com/kept.mp3',
        ),
      ],
      currentIndex: 0,
      position: Duration.zero,
      ownerKey: 'https://example.com\nalice',
      markingQueueId: 'queue-a',
    );
    SharedPreferences.setMockInitialValues({
      SharedPreferencesPlaybackQueueHistoryStore.storageKey: jsonEncode([
        valid.toJson(),
        {'version': PlaybackSessionSnapshot.version, 'queue': []},
      ]),
    });

    final restored = await const SharedPreferencesPlaybackQueueHistoryStore()
        .load();

    expect(restored, hasLength(1));
    expect(restored.single.queue.single.id, 'kept');
  });
}

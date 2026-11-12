import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';

void main() {
  const current = AudioTrack(id: 'current', title: 'Current', url: 'current');
  const next = AudioTrack(id: 'next', title: 'Next', url: 'next');
  const later = AudioTrack(id: 'later', title: 'Later', url: 'later');
  const incoming = AudioTrack(
    id: 'incoming',
    title: 'Incoming',
    url: 'incoming',
  );

  test('inserts a new item immediately after the current item', () {
    final mutation = planEnqueueNext(
      queue: const [current, next],
      currentIndex: 0,
      track: incoming,
    );

    expect(mutation.result, EnqueueNextResult.inserted);
    expect(mutation.queue.map((track) => track.id), [
      'current',
      'incoming',
      'next',
    ]);
    expect(mutation.currentIndex, 0);
  });

  test('moves an existing later item to next without duplication', () {
    final mutation = planEnqueueNext(
      queue: const [current, next, later],
      currentIndex: 0,
      track: later,
    );

    expect(mutation.result, EnqueueNextResult.moved);
    expect(mutation.queue.map((track) => track.id), [
      'current',
      'later',
      'next',
    ]);
  });

  test('moving an existing item preserves its queued display names', () {
    const queued = AudioTrack(
      id: 'later',
      title: 'Original',
      album: 'Original work',
      translatedTitle: 'First translation',
      translatedAlbum: 'First work translation',
      url: 'existing-url',
    );
    const selectedAgain = AudioTrack(
      id: 'later',
      title: 'Original',
      album: 'Original work',
      translatedTitle: 'Second translation',
      translatedAlbum: 'Second work translation',
      url: 'new-url',
    );
    final mutation = planEnqueueNext(
      queue: const [current, next, queued],
      currentIndex: 0,
      track: selectedAgain,
    );

    expect(mutation.result, EnqueueNextResult.moved);
    expect(mutation.queue[1].url, 'new-url');
    expect(mutation.queue[1].displayTitle, 'First translation');
    expect(mutation.queue[1].displayAlbum, 'First work translation');

    const queuedOriginal = AudioTrack(
      id: 'later',
      title: 'Original',
      album: 'Original work',
      url: 'existing-url',
    );
    final withoutTranslation = planEnqueueNext(
      queue: const [current, next, queuedOriginal],
      currentIndex: 0,
      track: selectedAgain,
    );
    expect(withoutTranslation.queue[1].url, 'new-url');
    expect(withoutTranslation.queue[1].translatedTitle, isNull);
    expect(withoutTranslation.queue[1].translatedAlbum, isNull);
    expect(withoutTranslation.queue[1].displayTitle, 'Original');
    expect(withoutTranslation.queue[1].displayAlbum, 'Original work');
  });

  test('moves an item from before current and preserves current identity', () {
    final mutation = planEnqueueNext(
      queue: const [later, current, next],
      currentIndex: 1,
      track: later,
    );

    expect(mutation.result, EnqueueNextResult.moved);
    expect(mutation.queue.map((track) => track.id), [
      'current',
      'later',
      'next',
    ]);
    expect(mutation.currentIndex, 0);
  });

  test('already-next and current-track operations are idempotent', () {
    final alreadyNext = planEnqueueNext(
      queue: const [current, next],
      currentIndex: 0,
      track: next,
    );
    final currentItem = planEnqueueNext(
      queue: const [current, next],
      currentIndex: 0,
      track: current,
    );

    expect(alreadyNext.result, EnqueueNextResult.alreadyNext);
    expect(alreadyNext.queue, const [current, next]);
    expect(currentItem.result, EnqueueNextResult.currentTrack);
    expect(currentItem.queue, const [current, next]);
  });

  test('reports no active queue without manufacturing a session', () {
    final mutation = planEnqueueNext(
      queue: const [],
      currentIndex: -1,
      track: incoming,
    );

    expect(mutation.result, EnqueueNextResult.noActiveQueue);
    expect(mutation.queue, isEmpty);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_slice.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/services/audio_slice_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('audio slices and state use value equality and immutable lists', () {
    const slice = AudioSlice(startMs: 1000, endMs: 2500);
    expect(slice, const AudioSlice(startMs: 1000, endMs: 2500));

    final source = <AudioSlice>[slice];
    final state = AudioSliceState.withValues(slices: source);
    source.add(const AudioSlice(startMs: 3000, endMs: 4000));

    expect(state.slices, [slice]);
    expect(
      () => state.slices.add(const AudioSlice(startMs: 3000, endMs: 4000)),
      throwsA(isA<UnsupportedError>()),
    );
    expect(state, AudioSliceState.withValues(slices: const [slice]));
  });

  test(
    'track identity survives URL changes and separates versions/chapters',
    () {
      const online = AudioTrack(
        id: 'hash-a',
        title: 'track.mp3',
        url: 'https://media.example/audio',
        workId: 41,
        hash: 'hash-a',
      );
      final cached = online.copyWith(url: 'file:///cache/audio');
      final downloaded = online.copyWith(
        url: 'file:///downloads/audio',
        sourcePath: '/downloads/audio',
      );
      const anotherVersion = AudioTrack(
        id: 'hash-b',
        title: 'track.mp3',
        url: 'https://media.example/audio-v2',
        workId: 41,
        hash: 'hash-b',
      );
      const firstChapter = AudioTrack(
        id: 'jp-41-chapter-1000',
        title: 'Chapter 1',
        url: 'https://jp.example/work.m3u8',
        workId: -41,
        hash: 'jp-41-chapter-1000',
        startTimeMs: 1000,
        endTimeMs: 5000,
      );
      const secondChapter = AudioTrack(
        id: 'jp-41-chapter-5000',
        title: 'Chapter 2',
        url: 'https://jp.example/work.m3u8',
        workId: -41,
        hash: 'jp-41-chapter-5000',
        startTimeMs: 5000,
        endTimeMs: 9000,
      );

      expect(audioSliceTrackKey(online), audioSliceTrackKey(cached));
      expect(audioSliceTrackKey(online), audioSliceTrackKey(downloaded));
      expect(
        audioSliceTrackKey(online),
        isNot(audioSliceTrackKey(anotherVersion)),
      );
      expect(
        audioSliceTrackKey(firstChapter),
        isNot(audioSliceTrackKey(secondChapter)),
      );
    },
  );

  test(
    'persistence reloads ranges under one track key and clears independently',
    () async {
      const store = SharedPreferencesAudioSliceStore();
      const first = AudioSlice(startMs: 1000, endMs: 2500);
      const second = AudioSlice(startMs: 3000, endMs: 4000);

      expect(await store.write('work:hash-a', [first, second]), isTrue);
      expect(await store.write('work:hash-b', [second]), isTrue);
      expect(await store.load('work:hash-a'), [first, second]);
      expect(await store.load('work:hash-b'), [second]);

      expect(await store.clear('work:hash-a'), isTrue);
      expect(await store.load('work:hash-a'), isEmpty);
      expect(await store.load('work:hash-b'), [second]);
    },
  );

  test('store rejects invalid, overlapping, or unsorted data', () async {
    const store = SharedPreferencesAudioSliceStore();

    await expectLater(
      store.write('track', const [AudioSlice(startMs: 10, endMs: 10)]),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      store.write('track', const [
        AudioSlice(startMs: 10, endMs: 30),
        AudioSlice(startMs: 20, endMs: 40),
      ]),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      store.write('track', const [
        AudioSlice(startMs: 30, endMs: 40),
        AudioSlice(startMs: 10, endMs: 20),
      ]),
      throwsA(isA<FormatException>()),
    );
  });

  test('failed slice writes restore the previous value', () async {
    const store = SharedPreferencesAudioSliceStore();
    const previous = AudioSlice(startMs: 1000, endMs: 2000);
    const replacement = AudioSlice(startMs: 3000, endMs: 4000);
    final key = SharedPreferencesAudioSliceStore.storageKey('track');
    final platform = _FailingPreferencesStore({
      'flutter.$key': '[{"startMs":1000,"endMs":2000}]',
    });
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = platform;

    platform.failNextSet = true;
    expect(await store.write('track', [replacement]), isFalse);
    expect(await store.load('track'), const [previous]);
    expect(platform.values['flutter.$key'], '[{"startMs":1000,"endMs":2000}]');
    SharedPreferences.resetStatic();
    expect(await store.load('track'), const [previous]);

    platform.throwNextSet = true;
    await expectLater(
      store.write('track', [replacement]),
      throwsA(isA<StateError>()),
    );
    expect(await store.load('track'), const [previous]);
    expect(platform.values['flutter.$key'], '[{"startMs":1000,"endMs":2000}]');
  });

  test('failed slice deletion restores the previous value', () async {
    const store = SharedPreferencesAudioSliceStore();
    const previous = AudioSlice(startMs: 1000, endMs: 2000);
    final key = SharedPreferencesAudioSliceStore.storageKey('track');
    final platform = _FailingPreferencesStore({
      'flutter.$key': '[{"startMs":1000,"endMs":2000}]',
    });
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = platform;

    platform.failNextRemove = true;
    expect(await store.clear('track'), isFalse);
    expect(await store.load('track'), const [previous]);
    expect(platform.values['flutter.$key'], '[{"startMs":1000,"endMs":2000}]');
    SharedPreferences.resetStatic();
    expect(await store.load('track'), const [previous]);

    platform.throwNextRemove = true;
    await expectLater(
      store.write('track', const []),
      throwsA(isA<StateError>()),
    );
    expect(await store.load('track'), const [previous]);
    expect(platform.values['flutter.$key'], '[{"startMs":1000,"endMs":2000}]');
  });
}

class _FailingPreferencesStore extends SharedPreferencesStorePlatform {
  _FailingPreferencesStore(this.values);

  final Map<String, Object> values;
  bool failNextSet = false;
  bool throwNextSet = false;
  bool failNextRemove = false;
  bool throwNextRemove = false;

  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    if (throwNextRemove) {
      throwNextRemove = false;
      throw StateError('remove failed');
    }
    if (failNextRemove) {
      failNextRemove = false;
      return false;
    }
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    values[key] = value;
    if (throwNextSet) {
      throwNextSet = false;
      throw StateError('set failed');
    }
    if (failNextSet) {
      failNextSet = false;
      return false;
    }
    return true;
  }
}

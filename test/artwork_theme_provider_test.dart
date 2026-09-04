import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/artwork_theme_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _descriptorProvider = StateProvider<ArtworkDescriptor?>((ref) => null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('artwork descriptor prefers the authenticated work cover', () {
    const track = AudioTrack(
      id: 'track-1',
      title: 'Track',
      url: 'https://example.test/audio.mp3',
      artworkUrl: 'https://example.test/fallback.jpg',
      workId: 42,
    );

    final descriptor = resolveArtworkDescriptor(
      track: track,
      host: 'example.test',
      token: 'secret',
    );

    expect(
      descriptor?.source,
      'https://example.test/api/cover/42?token=secret',
    );
    expect(descriptor?.cacheKey, 'work_cover_42');
    expect(descriptor?.trackIdentity, track.id);
  });

  test('artwork descriptor keeps a local cover offline', () {
    const track = AudioTrack(
      id: 'local-track',
      title: 'Local track',
      url: 'file:///audio.mp3',
      artworkUrl: 'file:///cover.jpg',
      workId: 42,
    );

    final descriptor = resolveArtworkDescriptor(
      track: track,
      host: '',
      token: '',
    );

    expect(descriptor?.source, track.artworkUrl);
  });

  test('privacy mode removes artwork from the global theme', () async {
    const descriptor = ArtworkDescriptor(
      trackIdentity: 'private-track',
      source: 'https://example.test/private.jpg',
      cacheKey: 'private',
    );
    final container = ProviderContainer(
      overrides: [
        currentArtworkDescriptorProvider.overrideWithValue(descriptor),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(themeArtworkDescriptorProvider), descriptor);

    await container
        .read(privacyModeSettingsProvider.notifier)
        .setBlurCoverInApp(true);
    await container.read(privacyModeSettingsProvider.notifier).setEnabled(true);

    expect(container.read(themeArtworkDescriptorProvider), isNull);
  });

  test('theme seed keeps the stable color and ignores late tracks', () async {
    final loader = _ControllableArtworkSeedLoader();
    final container = ProviderContainer(
      overrides: [
        themeArtworkDescriptorProvider.overrideWith(
          (ref) => ref.watch(_descriptorProvider),
        ),
        artworkSeedLoaderProvider.overrideWithValue(loader),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      artworkThemeSeedProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    const first = ArtworkDescriptor(
      trackIdentity: 'first',
      source: 'https://example.test/first.jpg',
      cacheKey: 'first',
    );
    const second = ArtworkDescriptor(
      trackIdentity: 'second',
      source: 'https://example.test/second.jpg',
      cacheKey: 'second',
    );
    const third = ArtworkDescriptor(
      trackIdentity: 'third',
      source: 'https://example.test/third.jpg',
      cacheKey: 'third',
    );

    container.read(_descriptorProvider.notifier).state = first;
    await _flushMicrotasks();
    container.read(_descriptorProvider.notifier).state = second;
    await _flushMicrotasks();
    loader.complete('first', Colors.red);
    await _flushMicrotasks();
    expect(container.read(artworkThemeSeedProvider).descriptor, second);
    expect(container.read(artworkThemeSeedProvider).seed, isNull);

    loader.complete('second', Colors.green);
    await _flushMicrotasks();
    final resolved = container.read(artworkThemeSeedProvider);
    expect(resolved.seed, Colors.green);
    expect(resolved.isLoading, isFalse);

    container.read(_descriptorProvider.notifier).state = third;
    await _flushMicrotasks();
    final loading = container.read(artworkThemeSeedProvider);
    expect(loading.isLoading, isTrue);
    expect(loading.seed, Colors.green);
    loader.complete('third', Colors.blue);
    await _flushMicrotasks();
    expect(container.read(artworkThemeSeedProvider).seed, Colors.blue);
  });

  test(
    'theme seed clears the retained color after extraction failure',
    () async {
      final loader = _ControllableArtworkSeedLoader();
      final container = ProviderContainer(
        overrides: [
          themeArtworkDescriptorProvider.overrideWith(
            (ref) => ref.watch(_descriptorProvider),
          ),
          artworkSeedLoaderProvider.overrideWithValue(loader),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        artworkThemeSeedProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      const first = ArtworkDescriptor(
        trackIdentity: 'first',
        source: 'https://example.test/first.jpg',
        cacheKey: 'first',
      );
      const failed = ArtworkDescriptor(
        trackIdentity: 'failed',
        source: 'https://example.test/failed.jpg',
        cacheKey: 'failed',
      );
      container.read(_descriptorProvider.notifier).state = first;
      await _flushMicrotasks();
      loader.complete('first', Colors.green);
      await _flushMicrotasks();

      container.read(_descriptorProvider.notifier).state = failed;
      await _flushMicrotasks();
      expect(container.read(artworkThemeSeedProvider).seed, Colors.green);
      await _flushMicrotasks();
      loader.fail('failed');
      await _flushMicrotasks();

      final state = container.read(artworkThemeSeedProvider);
      expect(state.seed, isNull);
      expect(state.failed, isTrue);
    },
  );
}

Future<void> _flushMicrotasks() async {
  for (var index = 0; index < 5; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _ControllableArtworkSeedLoader implements ArtworkSeedLoader {
  final Map<String, List<Completer<Color>>> _loads = {};

  @override
  Future<Color> load(ArtworkSeedRequest request) {
    final completer = Completer<Color>();
    _loads.putIfAbsent(request.cacheKey, () => []).add(completer);
    return completer.future;
  }

  void complete(String key, Color color) {
    _loads[key]!.firstWhere((load) => !load.isCompleted).complete(color);
  }

  void fail(String key) {
    _loads[key]!
        .firstWhere((load) => !load.isCompleted)
        .completeError(StateError('failed'));
  }
}

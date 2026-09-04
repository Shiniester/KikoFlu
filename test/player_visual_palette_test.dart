import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/artwork_theme_provider.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_visual_palette.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(clearArtworkSeedCache);

  test('generated palette keeps readable foreground contrast', () {
    final palette = PlayerVisualPalette.fromDominant(
      const Color(0xFFE53935),
      brightness: Brightness.dark,
    );
    final representative = Color.lerp(
      palette.backgroundStart,
      palette.backgroundEnd,
      0.5,
    )!;

    expect(_contrast(palette.foreground, representative), greaterThan(4.5));
    expect(palette.panelColor.a, lessThan(0.2));
  });

  test('artwork palette cache stays bounded', () async {
    final cache = ArtworkSeedCache(
      maxEntries: artworkSeedCacheCapacity,
      extractor: (_) => Future<Color>.value(Colors.blue),
    );
    for (var index = 0; index < artworkSeedCacheCapacity + 6; index++) {
      await cache.load(
        ArtworkSeedRequest(
          source: 'https://example.test/cover-$index.jpg',
          cacheKey: 'cover-$index',
        ),
      );
    }

    expect(cache.length, artworkSeedCacheCapacity);
  });

  test('the same artwork reuses one in-flight extraction', () async {
    final extraction = Completer<Color>();
    var extractionCount = 0;
    final cache = ArtworkSeedCache(
      maxEntries: artworkSeedCacheCapacity,
      extractor: (_) {
        extractionCount++;
        return extraction.future;
      },
    );
    const request = ArtworkSeedRequest(
      source: 'https://example.test/cover.jpg',
      cacheKey: 'cover',
    );

    final first = cache.load(request);
    final second = cache.load(request);

    expect(identical(first, second), isTrue);
    expect(extractionCount, 1);
    extraction.complete(Colors.amber);
    expect(await first, Colors.amber);
    expect(await second, Colors.amber);
    expect(cache.length, 1);
  });

  test('the same cache key stays isolated across artwork sources', () async {
    final extractions = <String, Completer<Color>>{};
    var extractionCount = 0;
    final cache = ArtworkSeedCache(
      maxEntries: artworkSeedCacheCapacity,
      extractor: (request) {
        extractionCount++;
        return (extractions[request.source] ??= Completer<Color>()).future;
      },
    );
    const firstRequest = ArtworkSeedRequest(
      source: 'https://first.example/api/cover/42?token=first',
      cacheKey: 'work_cover_42',
    );
    const secondRequest = ArtworkSeedRequest(
      source: 'https://second.example/api/cover/42?token=second',
      cacheKey: 'work_cover_42',
    );

    final first = cache.load(firstRequest);
    final second = cache.load(secondRequest);

    expect(identical(first, second), isFalse);
    expect(extractionCount, 2);
    extractions[firstRequest.source]!.complete(Colors.red);
    extractions[secondRequest.source]!.complete(Colors.blue);
    expect(await first, Colors.red);
    expect(await second, Colors.blue);
    expect(await cache.load(firstRequest), Colors.red);
    expect(await cache.load(secondRequest), Colors.blue);
    expect(extractionCount, 2);
  });

  test('failed artwork extraction is not cached', () async {
    var extractionCount = 0;
    final cache = ArtworkSeedCache(
      maxEntries: artworkSeedCacheCapacity,
      extractor: (_) {
        extractionCount++;
        return Future<Color>.error(StateError('failed'));
      },
    );
    const request = ArtworkSeedRequest(
      source: 'https://example.test/cover.jpg',
      cacheKey: 'cover',
    );

    await expectLater(cache.load(request), throwsStateError);
    await expectLater(cache.load(request), throwsStateError);

    expect(extractionCount, 2);
    expect(cache.length, 0);
  });

  test('player accent follows the application theme', () {
    const themeAccent = Color(0xFF6750A4);
    const onThemeAccent = Colors.white;
    final palette = PlayerVisualPalette.fromDominant(
      const Color(0xFFE53935),
      brightness: Brightness.light,
      accent: themeAccent,
      onAccent: onThemeAccent,
    );

    expect(palette.accent, themeAccent);
    expect(palette.onAccent, onThemeAccent);
  });
}

double _contrast(Color first, Color second) {
  final bright = first.computeLuminance() > second.computeLuminance()
      ? first.computeLuminance()
      : second.computeLuminance();
  final dark = first.computeLuminance() > second.computeLuminance()
      ? second.computeLuminance()
      : first.computeLuminance();
  return (bright + 0.05) / (dark + 0.05);
}

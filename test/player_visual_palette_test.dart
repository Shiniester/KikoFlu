import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_visual_palette.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(clearPlayerVisualPaletteCache);

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

  test('artwork palette cache stays bounded', () {
    final palette = PlayerVisualPalette.fallback(
      seed: Colors.blue,
      brightness: Brightness.dark,
    );
    for (var index = 0; index < playerVisualPaletteCacheCapacity + 6; index++) {
      debugStorePlayerVisualPalette('cover-$index', palette);
    }

    expect(playerVisualPaletteCacheSize, playerVisualPaletteCacheCapacity);
  });

  test('the same artwork reuses one in-flight extraction', () async {
    const request = PlayerPaletteRequest(
      source: 'file:///definitely-missing-player-cover.png',
      cacheKey: 'missing-cover',
      brightness: Brightness.dark,
      fallbackSeed: Colors.indigo,
      suppressArtwork: false,
    );

    final first = debugLoadPlayerVisualPalette(request);
    final second = debugLoadPlayerVisualPalette(request);

    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(playerVisualPaletteCacheSize, 1);
  });

  test('privacy fallback skips extraction and cache population', () async {
    const request = PlayerPaletteRequest(
      source: 'https://example.invalid/private-cover.jpg',
      cacheKey: 'private-cover',
      brightness: Brightness.light,
      fallbackSeed: Colors.teal,
      suppressArtwork: true,
    );

    final palette = await debugLoadPlayerVisualPalette(request);

    expect(palette.backgroundStart, isNotNull);
    expect(playerVisualPaletteCacheSize, 0);
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

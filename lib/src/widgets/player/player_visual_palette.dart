import 'dart:async';
import 'dart:collection';
import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/local_file_url.dart';

@immutable
class PlayerVisualPalette {
  const PlayerVisualPalette({
    required this.backgroundStart,
    required this.backgroundMiddle,
    required this.backgroundEnd,
    required this.foreground,
    required this.secondaryForeground,
    required this.accent,
    required this.onAccent,
    required this.panelColor,
    required this.panelStroke,
  });

  final Color backgroundStart;
  final Color backgroundMiddle;
  final Color backgroundEnd;
  final Color foreground;
  final Color secondaryForeground;
  final Color accent;
  final Color onAccent;
  final Color panelColor;
  final Color panelStroke;

  factory PlayerVisualPalette.fallback({
    required Color seed,
    required Brightness brightness,
  }) {
    return PlayerVisualPalette.fromDominant(seed, brightness: brightness);
  }

  factory PlayerVisualPalette.fromDominant(
    Color dominant, {
    required Brightness brightness,
  }) {
    final sourceHsl = HSLColor.fromColor(dominant);
    final saturation = sourceHsl.saturation.clamp(0.28, 0.72);
    final startLightness = brightness == Brightness.dark ? 0.12 : 0.58;
    final middleLightness = brightness == Brightness.dark ? 0.21 : 0.70;
    final endLightness = brightness == Brightness.dark ? 0.33 : 0.82;

    final start = sourceHsl
        .withSaturation(saturation)
        .withLightness(startLightness)
        .toColor();
    final middle = sourceHsl
        .withHue((sourceHsl.hue + 8) % 360)
        .withSaturation((saturation * 0.88).clamp(0.22, 0.68))
        .withLightness(middleLightness)
        .toColor();
    final end = sourceHsl
        .withHue((sourceHsl.hue + 18) % 360)
        .withSaturation((saturation * 0.72).clamp(0.18, 0.62))
        .withLightness(endLightness)
        .toColor();

    final representative = Color.lerp(start, end, 0.5)!;
    final foreground = _bestForeground(representative);
    final accent = sourceHsl
        .withSaturation((saturation + 0.12).clamp(0.36, 0.82))
        .withLightness(foreground == Colors.white ? 0.72 : 0.34)
        .toColor();
    final onAccent = _bestForeground(accent);

    return PlayerVisualPalette(
      backgroundStart: start,
      backgroundMiddle: middle,
      backgroundEnd: end,
      foreground: foreground,
      secondaryForeground: foreground.withValues(alpha: 0.66),
      accent: accent,
      onAccent: onAccent,
      panelColor: foreground.withValues(
        alpha: foreground == Colors.white ? 0.10 : 0.07,
      ),
      panelStroke: foreground.withValues(alpha: 0.13),
    );
  }

  static Color _bestForeground(Color background) {
    final luminance = background.computeLuminance();
    final whiteContrast = 1.05 / (luminance + 0.05);
    final blackContrast = (luminance + 0.05) / 0.05;
    return whiteContrast >= blackContrast ? Colors.white : Colors.black;
  }
}

@immutable
class PlayerPaletteRequest {
  const PlayerPaletteRequest({
    required this.source,
    required this.cacheKey,
    required this.brightness,
    required this.fallbackSeed,
    required this.suppressArtwork,
  });

  final String? source;
  final String? cacheKey;
  final Brightness brightness;
  final Color fallbackSeed;
  final bool suppressArtwork;

  String get effectiveCacheKey =>
      '${cacheKey ?? source ?? 'fallback'}:${brightness.name}';

  @override
  bool operator ==(Object other) {
    return other is PlayerPaletteRequest &&
        other.source == source &&
        other.cacheKey == cacheKey &&
        other.brightness == brightness &&
        other.fallbackSeed == fallbackSeed &&
        other.suppressArtwork == suppressArtwork;
  }

  @override
  int get hashCode =>
      Object.hash(source, cacheKey, brightness, fallbackSeed, suppressArtwork);
}

final playerVisualPaletteProvider = FutureProvider.autoDispose
    .family<PlayerVisualPalette, PlayerPaletteRequest>((ref, request) {
      return _playerPaletteCache.load(request);
    });

const int playerVisualPaletteCacheCapacity = 64;

final _playerPaletteCache = _PlayerPaletteCache(
  maxEntries: playerVisualPaletteCacheCapacity,
);

@visibleForTesting
int get playerVisualPaletteCacheSize => _playerPaletteCache.length;

@visibleForTesting
void clearPlayerVisualPaletteCache() => _playerPaletteCache.clear();

@visibleForTesting
Future<PlayerVisualPalette> debugLoadPlayerVisualPalette(
  PlayerPaletteRequest request,
) => _playerPaletteCache.load(request);

@visibleForTesting
void debugStorePlayerVisualPalette(String key, PlayerVisualPalette palette) =>
    _playerPaletteCache.storeForTesting(key, palette);

class _PlayerPaletteCache {
  _PlayerPaletteCache({required this.maxEntries});

  final int maxEntries;
  final LinkedHashMap<String, Future<PlayerVisualPalette>> _entries =
      LinkedHashMap<String, Future<PlayerVisualPalette>>();

  int get length => _entries.length;

  void clear() => _entries.clear();

  void storeForTesting(String key, PlayerVisualPalette palette) {
    _entries.remove(key);
    _entries[key] = SynchronousFuture<PlayerVisualPalette>(palette);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  Future<PlayerVisualPalette> load(PlayerPaletteRequest request) {
    final fallback = PlayerVisualPalette.fallback(
      seed: request.fallbackSeed,
      brightness: request.brightness,
    );
    if (request.suppressArtwork || request.source == null) {
      return SynchronousFuture<PlayerVisualPalette>(fallback);
    }

    final key = request.effectiveCacheKey;
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return cached;
    }

    final pending =
        _extractDominantColor(request.source!, cacheKey: request.cacheKey).then(
          (dominant) => PlayerVisualPalette.fromDominant(
            dominant,
            brightness: request.brightness,
          ),
          onError: (_) => fallback,
        );
    _entries[key] = pending;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return pending;
  }
}

Future<Color> _extractDominantColor(String source, {String? cacheKey}) async {
  final ImageProvider<Object> imageProvider;
  if (LocalFileUrl.isLocalFileUrl(source)) {
    final path = LocalFileUrl.pathFromUrl(source);
    if (path == null) throw StateError('Invalid local artwork URL');
    imageProvider = ResizeImage(
      FileImage(File(path)),
      width: 32,
      height: 32,
      allowUpscaling: false,
    );
  } else {
    imageProvider = ResizeImage(
      CachedNetworkImageProvider(source, cacheKey: cacheKey),
      width: 32,
      height: 32,
      allowUpscaling: false,
    );
  }

  final completer = Completer<ui.Image>();
  final stream = imageProvider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (imageInfo, synchronousCall) {
      if (!completer.isCompleted) completer.complete(imageInfo.image);
    },
    onError: (Object error, StackTrace? stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
  );
  stream.addListener(listener);

  try {
    final image = await completer.future.timeout(const Duration(seconds: 8));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null || bytes.lengthInBytes < 4) {
      throw StateError('Artwork could not be sampled');
    }

    var red = 0.0;
    var green = 0.0;
    var blue = 0.0;
    var totalWeight = 0.0;
    final data = bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    for (var index = 0; index + 3 < data.length; index += 4) {
      final alpha = data[index + 3] / 255.0;
      if (alpha < 0.2) continue;
      final pixelRed = data[index];
      final pixelGreen = data[index + 1];
      final pixelBlue = data[index + 2];
      final maxChannel = pixelRed > pixelGreen
          ? (pixelRed > pixelBlue ? pixelRed : pixelBlue)
          : (pixelGreen > pixelBlue ? pixelGreen : pixelBlue);
      final minChannel = pixelRed < pixelGreen
          ? (pixelRed < pixelBlue ? pixelRed : pixelBlue)
          : (pixelGreen < pixelBlue ? pixelGreen : pixelBlue);
      final saturationWeight = 0.35 + (maxChannel - minChannel) / 255.0;
      final weight = alpha * saturationWeight;
      red += pixelRed * weight;
      green += pixelGreen * weight;
      blue += pixelBlue * weight;
      totalWeight += weight;
    }
    if (totalWeight == 0) throw StateError('Artwork has no visible pixels');
    return Color.fromARGB(
      255,
      (red / totalWeight).round().clamp(0, 255),
      (green / totalWeight).round().clamp(0, 255),
      (blue / totalWeight).round().clamp(0, 255),
    );
  } finally {
    stream.removeListener(listener);
  }
}

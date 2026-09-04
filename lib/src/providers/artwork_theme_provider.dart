import 'dart:async';
import 'dart:collection';
import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/audio_track.dart';
import '../utils/local_file_url.dart';
import 'audio_provider.dart';
import 'auth_provider.dart';
import 'settings_provider.dart';

@immutable
class ArtworkSeedRequest {
  const ArtworkSeedRequest({required this.source, required this.cacheKey});

  final String source;
  final String cacheKey;

  String get cacheIdentity => '$cacheKey\u0000$source';

  @override
  bool operator ==(Object other) {
    return other is ArtworkSeedRequest &&
        other.source == source &&
        other.cacheKey == cacheKey;
  }

  @override
  int get hashCode => Object.hash(source, cacheKey);
}

@immutable
class ArtworkDescriptor {
  const ArtworkDescriptor({
    required this.trackIdentity,
    required this.source,
    required this.cacheKey,
  });

  final String trackIdentity;
  final String source;
  final String cacheKey;

  ArtworkSeedRequest get seedRequest =>
      ArtworkSeedRequest(source: source, cacheKey: cacheKey);

  @override
  bool operator ==(Object other) {
    return other is ArtworkDescriptor &&
        other.trackIdentity == trackIdentity &&
        other.source == source &&
        other.cacheKey == cacheKey;
  }

  @override
  int get hashCode => Object.hash(trackIdentity, source, cacheKey);
}

String? resolveArtworkSource({
  required int? workId,
  required String? artworkUrl,
  required String host,
  required String token,
}) {
  if (LocalFileUrl.isLocalFileUrl(artworkUrl)) return artworkUrl;

  if (workId != null && host.isNotEmpty) {
    final normalizedHost =
        host.startsWith('http://') || host.startsWith('https://')
        ? host
        : 'https://$host';
    return token.isNotEmpty
        ? '$normalizedHost/api/cover/$workId?token=$token'
        : '$normalizedHost/api/cover/$workId';
  }

  return artworkUrl == null || artworkUrl.isEmpty ? null : artworkUrl;
}

ArtworkDescriptor? resolveArtworkDescriptor({
  required AudioTrack? track,
  required String host,
  required String token,
}) {
  if (track == null) return null;

  final source = resolveArtworkSource(
    workId: track.workId,
    artworkUrl: track.artworkUrl,
    host: host,
    token: token,
  );
  if (source == null) return null;

  return ArtworkDescriptor(
    trackIdentity: track.id,
    source: source,
    cacheKey: track.workId != null
        ? 'work_cover_${track.workId}'
        : track.hash ?? source,
  );
}

final currentArtworkDescriptorProvider = Provider<ArtworkDescriptor?>((ref) {
  final track = ref.watch(currentTrackProvider).valueOrNull;
  final auth = ref.watch(
    authProvider.select(
      (state) => (host: state.host ?? '', token: state.token ?? ''),
    ),
  );
  return resolveArtworkDescriptor(
    track: track,
    host: auth.host,
    token: auth.token,
  );
});

final themeArtworkDescriptorProvider = Provider<ArtworkDescriptor?>((ref) {
  final suppressArtwork = ref.watch(
    privacyModeSettingsProvider.select(
      (settings) => settings.enabled && settings.blurCoverInApp,
    ),
  );
  return suppressArtwork ? null : ref.watch(currentArtworkDescriptorProvider);
});

abstract interface class ArtworkSeedLoader {
  Future<Color> load(ArtworkSeedRequest request);
}

typedef ArtworkSeedExtractor =
    Future<Color> Function(ArtworkSeedRequest request);

final artworkSeedLoaderProvider = Provider<ArtworkSeedLoader>((ref) {
  return _cachedArtworkSeedLoader;
});

const int artworkSeedCacheCapacity = 64;

final _cachedArtworkSeedLoader = ArtworkSeedCache(
  maxEntries: artworkSeedCacheCapacity,
);

@visibleForTesting
int get artworkSeedCacheSize => _cachedArtworkSeedLoader.length;

@visibleForTesting
void clearArtworkSeedCache() => _cachedArtworkSeedLoader.clear();

class ArtworkSeedCache implements ArtworkSeedLoader {
  ArtworkSeedCache({required this.maxEntries, ArtworkSeedExtractor? extractor})
    : _extractor = extractor ?? _extractArtworkSeed;

  final int maxEntries;
  final ArtworkSeedExtractor _extractor;
  final LinkedHashMap<String, Color> _resolved = LinkedHashMap<String, Color>();
  final Map<String, Future<Color>> _inFlight = <String, Future<Color>>{};

  int get length => _resolved.length;

  void clear() {
    _resolved.clear();
    _inFlight.clear();
  }

  void _store(String key, Color seed) {
    _resolved.remove(key);
    _resolved[key] = seed;
    while (_resolved.length > maxEntries) {
      _resolved.remove(_resolved.keys.first);
    }
  }

  @override
  Future<Color> load(ArtworkSeedRequest request) {
    final key = request.cacheIdentity;
    if (_resolved.containsKey(key)) {
      final seed = _resolved.remove(key)!;
      _resolved[key] = seed;
      return SynchronousFuture<Color>(seed);
    }

    final pending = _inFlight[key];
    if (pending != null) return pending;

    final extraction = _extractor(request)
        .then((seed) {
          _store(key, seed);
          return seed;
        })
        .whenComplete(() {
          _inFlight.remove(key);
        });
    _inFlight[key] = extraction;
    return extraction;
  }
}

@immutable
class ArtworkThemeSeedState {
  const ArtworkThemeSeedState({
    this.descriptor,
    this.seed,
    this.isLoading = false,
    this.failed = false,
  });

  final ArtworkDescriptor? descriptor;
  final Color? seed;
  final bool isLoading;
  final bool failed;
}

class ArtworkThemeSeedNotifier extends StateNotifier<ArtworkThemeSeedState> {
  ArtworkThemeSeedNotifier(this._ref) : super(const ArtworkThemeSeedState()) {
    _subscription = _ref.listen<ArtworkDescriptor?>(
      themeArtworkDescriptorProvider,
      (_, descriptor) => _select(descriptor),
    );
    _select(_ref.read(themeArtworkDescriptorProvider));
  }

  final Ref _ref;
  late final ProviderSubscription<ArtworkDescriptor?> _subscription;
  int _revision = 0;

  void _select(ArtworkDescriptor? descriptor) {
    final revision = ++_revision;
    if (descriptor == null) {
      state = const ArtworkThemeSeedState();
      return;
    }

    state = ArtworkThemeSeedState(
      descriptor: descriptor,
      seed: state.seed,
      isLoading: true,
    );
    unawaited(_load(descriptor, revision));
  }

  Future<void> _load(ArtworkDescriptor descriptor, int revision) async {
    try {
      final seed = await _ref
          .read(artworkSeedLoaderProvider)
          .load(descriptor.seedRequest);
      if (!mounted || revision != _revision) return;
      state = ArtworkThemeSeedState(descriptor: descriptor, seed: seed);
    } catch (_) {
      if (!mounted || revision != _revision) return;
      state = ArtworkThemeSeedState(descriptor: descriptor, failed: true);
    }
  }

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}

final artworkThemeSeedProvider =
    StateNotifierProvider.autoDispose<
      ArtworkThemeSeedNotifier,
      ArtworkThemeSeedState
    >((ref) {
      return ArtworkThemeSeedNotifier(ref);
    });

Future<Color> _extractArtworkSeed(ArtworkSeedRequest request) async {
  final ImageProvider<Object> imageProvider;
  if (LocalFileUrl.isLocalFileUrl(request.source)) {
    final path = LocalFileUrl.pathFromUrl(request.source);
    if (path == null) throw StateError('Invalid local artwork URL');
    imageProvider = ResizeImage(
      FileImage(File(path)),
      width: 32,
      height: 32,
      allowUpscaling: false,
    );
  } else {
    imageProvider = ResizeImage(
      CachedNetworkImageProvider(request.source, cacheKey: request.cacheKey),
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

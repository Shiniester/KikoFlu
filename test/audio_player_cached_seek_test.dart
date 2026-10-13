import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/services/audio_cache_downloader.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/speculative_transfer_coordinator.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_latest_request_test.dart'
    show ControlledPlayer, MemorySessionStore, until;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late List<AudioPlayerService> services;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SpeculativeTransferCoordinator.instance.resetForTest();
    services = [];
    SharedPreferences.setMockInitialValues({
      'server_host': 'https://example.invalid',
      'current_user': '{"name":"tester"}',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    root = await Directory.systemTemp.createTemp('kiko-cached-seek-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
  });

  tearDown(() async {
    for (final service in services) {
      await service.dispose();
    }
    SpeculativeTransferCoordinator.instance.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    await root.delete(recursive: true);
  });

  AudioPlayerService createService(ControlledPlayer player) {
    final service = AudioPlayerService.forTesting(
      player,
      sessionStore: MemorySessionStore(),
      androidSeekRecovery: true,
      cacheDownloader: _NoopCacheDownloader(),
    );
    services.add(service);
    return service;
  }

  Future<String> createCompleteCache(String hash) async {
    final partial = await CacheService.prepareAudioCacheTempFile(hash);
    await partial.writeAsBytes([1, 2, 3, 4]);
    expect(
      await CacheService.finalizeAudioCacheFile(hash, expectedSize: 4),
      isTrue,
    );
    return CacheService.audioCacheFinalPath(hash);
  }

  test(
    'distant Android seek loads a complete cache without republishing',
    () async {
      final player = _CachedSeekPlayer()
        ..bufferedPosition = const Duration(seconds: 10);
      final service = createService(player);
      const track = AudioTrack(
        id: 'cached-seek',
        title: 'cached-seek.flac',
        url: 'https://example.invalid/cached-seek.flac',
        hash: 'cached-seek-audio',
      );
      final publications = <AudioTrack?>[];
      final subscription = service.currentTrackStream.listen(publications.add);
      await service.updateQueue([track], autoplay: true);
      await until(() => publications.length == 1);
      final cachePath = await createCompleteCache(track.hash!);
      const target = Duration(seconds: 30);

      await service.seek(const Duration(seconds: 8));
      expect(player.loaded, [track.url]);
      expect(player.seeks, [const Duration(seconds: 8)]);
      expect(player.audioSource, isA<UriAudioSource>());
      expect((player.audioSource as UriAudioSource).uri.scheme, 'https');

      await service.seek(target);

      expect(player.loaded, [track.url, cachePath]);
      expect(player.initialPositions, [null, target]);
      expect(player.seeks, [const Duration(seconds: 8)]);
      expect(player.audioSource, isA<UriAudioSource>());
      expect((player.audioSource as UriAudioSource).uri.scheme, 'file');
      expect(player.playing, isTrue);
      expect(publications.map((item) => item?.id), [track.id]);
      await subscription.cancel();
    },
  );

  test('buffered and partial-cache seeks keep the remote source', () async {
    final player = _CachedSeekPlayer()
      ..bufferedPosition = const Duration(seconds: 10);
    final service = createService(player);
    const track = AudioTrack(
      id: 'partial-seek',
      title: 'partial-seek.flac',
      url: 'https://example.invalid/partial-seek.flac',
      hash: 'partial-seek-audio',
    );
    await service.updateQueue([track], autoplay: true);
    final remoteSource = player.audioSource;
    final partial = await CacheService.prepareAudioCacheTempFile(track.hash!);
    await partial.writeAsBytes([1, 2, 3, 4]);

    await service.seek(const Duration(seconds: 8));
    await service.seek(const Duration(seconds: 30));

    expect(player.audioSource, same(remoteSource));
    expect(player.loaded, [track.url]);
    expect(player.seeks, [
      const Duration(seconds: 8),
      const Duration(seconds: 30),
    ]);
  });

  test('a paused distant seek uses cache without resuming playback', () async {
    final player = _CachedSeekPlayer()
      ..bufferedPosition = const Duration(seconds: 5);
    final service = createService(player);
    const track = AudioTrack(
      id: 'paused-cached-seek',
      title: 'paused-cached-seek.flac',
      url: 'https://example.invalid/paused-cached-seek.flac',
      hash: 'paused-cached-seek-audio',
    );
    await service.updateQueue([track]);
    final cachePath = await createCompleteCache(track.hash!);
    const target = Duration(seconds: 30);

    await service.seek(target);

    expect(player.loaded, [track.url, cachePath]);
    expect(player.initialPositions, [null, target]);
    expect(player.playing, isFalse);
    expect(player.played, isEmpty);
  });

  test('the newest seek wins while a cache lookup is pending', () async {
    final player = _CachedSeekPlayer()
      ..bufferedPosition = const Duration(seconds: 5);
    final service = createService(player);
    const track = AudioTrack(
      id: 'latest-cached-seek',
      title: 'latest-cached-seek.flac',
      url: 'https://example.invalid/latest-cached-seek.flac',
      hash: 'latest-cached-seek-audio',
    );
    await service.updateQueue([track], autoplay: true);
    final cachePath = await createCompleteCache(track.hash!);
    final earlier = service.seek(const Duration(seconds: 20));
    final latest = service.seek(const Duration(seconds: 40));

    await Future.wait([earlier, latest]);

    expect(player.loaded, [track.url, cachePath]);
    expect(player.initialPositions, [null, const Duration(seconds: 40)]);
    expect(player.position, const Duration(seconds: 40));
  });

  test('stop during cache lookup prevents a stale cached reload', () async {
    final player = _CachedSeekPlayer()
      ..bufferedPosition = const Duration(seconds: 5);
    final service = createService(player);
    const track = AudioTrack(
      id: 'stopped-cached-seek',
      title: 'stopped-cached-seek.flac',
      url: 'https://example.invalid/stopped-cached-seek.flac',
      hash: 'stopped-cached-seek-audio',
    );
    await service.updateQueue([track], autoplay: true);
    await createCompleteCache(track.hash!);
    final seeking = service.seek(const Duration(seconds: 30));
    final stopping = service.stop();

    await Future.wait([seeking, stopping]);

    expect(player.loaded, [track.url]);
    expect(player.playing, isFalse);
    expect(player.played, [track.url]);
  });

  test(
    'a new track during cache lookup prevents the old cached reload',
    () async {
      final player = _CachedSeekPlayer()
        ..bufferedPosition = const Duration(seconds: 5);
      final service = createService(player);
      const current = AudioTrack(
        id: 'replaced-cached-seek',
        title: 'replaced-cached-seek.flac',
        url: 'https://example.invalid/replaced-cached-seek.flac',
        hash: 'replaced-cached-seek-audio',
      );
      const next = AudioTrack(
        id: 'replacement-track',
        title: 'replacement-track.flac',
        url: 'https://example.invalid/replacement-track.flac',
      );
      await service.updateQueue([current], autoplay: true);
      final oldCachePath = await createCompleteCache(current.hash!);
      final seeking = service.seek(const Duration(seconds: 30));
      final loadingNext = service.updateQueue([next], autoplay: true);

      await Future.wait([seeking, loadingNext]);

      expect(player.loaded, [current.url, next.url]);
      expect(player.loaded, isNot(contains(oldCachePath)));
      expect(service.currentTrack?.id, next.id);
      expect(player.audioSource, isA<UriAudioSource>());
      expect((player.audioSource as UriAudioSource).uri.toString(), next.url);
      expect(player.playing, isTrue);
    },
  );

  test('an unplayable cached seek falls back to the remote source', () async {
    final player = _CachedSeekPlayer()
      ..bufferedPosition = const Duration(seconds: 5);
    final service = createService(player);
    const track = AudioTrack(
      id: 'failed-cached-seek',
      title: 'failed-cached-seek.flac',
      url: 'https://example.invalid/failed-cached-seek.flac',
      hash: 'failed-cached-seek-audio',
    );
    await service.updateQueue([track], autoplay: true);
    await createCompleteCache(track.hash!);
    player.failFileAudioSource = true;
    const target = Duration(seconds: 30);

    await service.seek(target);

    expect(player.audioSource, isA<UriAudioSource>());
    expect((player.audioSource as UriAudioSource).uri.scheme, 'https');
    expect(player.initialPositions, [null, target]);
    expect(player.position, target);
    expect(player.playing, isTrue);
  });
}

class _CachedSeekPlayer extends ControlledPlayer {
  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();
}

class _NoopCacheDownloader extends AudioCacheDownloader {
  _NoopCacheDownloader() : super(files: CacheService.audioCacheFiles);

  @override
  Future<bool> setTarget(AudioCacheRequest? request) async => false;
}

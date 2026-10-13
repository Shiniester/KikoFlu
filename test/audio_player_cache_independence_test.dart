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
import 'package:kikoeru_flutter/src/services/download_service.dart';
import 'package:kikoeru_flutter/src/services/speculative_transfer_coordinator.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_latest_request_test.dart'
    show ControlledPlayer, MemorySessionStore, until;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ControlledPlayer player;
  late _PendingCacheDownloader downloader;
  late AudioPlayerService service;
  String? downloadedTaskId;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SpeculativeTransferCoordinator.instance.resetForTest();
    SharedPreferences.setMockInitialValues({
      'server_host': 'https://example.invalid',
      'current_user': '{"name":"tester"}',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    root = await Directory.systemTemp.createTemp('kiko-cache-independent-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
    player = ControlledPlayer();
    downloader = _PendingCacheDownloader();
    downloadedTaskId = null;
    service = AudioPlayerService.forTesting(
      player,
      sessionStore: MemorySessionStore(),
      cacheDownloader: downloader,
    );
    service.updatePreloadThreshold(null);
  });

  tearDown(() async {
    final invalidationGate = downloader.invalidateGate;
    if (invalidationGate != null && !invalidationGate.isCompleted) {
      invalidationGate.complete();
    }
    await service.dispose();
    SpeculativeTransferCoordinator.instance.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    final taskId = downloadedTaskId;
    if (taskId != null) await DownloadService.instance.deleteTask(taskId);
    await root.delete(recursive: true);
  });

  test(
    'pending cache work never blocks native playback controls or switching',
    () async {
      const current = AudioTrack(
        id: 'current',
        title: 'current.flac',
        url: 'https://example.invalid/current.flac',
        hash: 'current-audio',
      );
      const next = AudioTrack(
        id: 'next',
        title: 'next.wav',
        url: 'https://example.invalid/next.wav',
      );

      await service
          .updateQueue([current], autoplay: true)
          .timeout(const Duration(seconds: 2));
      expect(player.audioSource, isA<UriAudioSource>());
      expect(downloader.targets.single?.hash, current.hash);
      final remoteSource = player.audioSource;
      downloader.complete(current.hash!, result: false);

      await service
          .seek(const Duration(seconds: 20))
          .timeout(const Duration(seconds: 2));
      await service.pause().timeout(const Duration(seconds: 2));
      expect(player.playing, isFalse);

      await service.play().timeout(const Duration(seconds: 2));
      await service.stop().timeout(const Duration(seconds: 2));
      await service
          .updateQueue([next], autoplay: true)
          .timeout(const Duration(seconds: 2));

      expect(player.audioSource, isA<UriAudioSource>());
      expect(player.audioSource, isNot(same(remoteSource)));
      expect(player.loaded, [current.url, next.url]);
      expect(downloader.targets, contains(null));
    },
  );

  test(
    'preload target follows the threshold and returns to current on seek',
    () async {
      const current = AudioTrack(
        id: 'current-preload',
        title: 'current.flac',
        url: 'https://example.invalid/current.flac',
        hash: 'current-preload-audio',
      );
      const next = AudioTrack(
        id: 'next-preload',
        title: 'next.flac',
        url: 'https://example.invalid/next.flac',
        hash: 'next-preload-audio',
      );
      service.updatePreloadThreshold(const Duration(seconds: 30));

      await service.updateQueue([current, next], autoplay: true);
      expect(downloader.targets.last?.hash, current.hash);

      player.position = const Duration(minutes: 4, seconds: 40);
      player.positions.add(player.position);
      expect(downloader.targets.last?.hash, next.hash);

      await service.seek(Duration.zero);
      await until(() => downloader.targets.last?.hash == current.hash);
      expect(downloader.targets.last?.hash, current.hash);

      await service.pause();
      expect(downloader.targets.last, isNull);
      await service.play();
      await service.stop();
      expect(downloader.targets.last, isNull);
    },
  );

  test('Android remote cache waits for playback buffer headroom', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const current = AudioTrack(
      id: 'current-buffered',
      title: 'current-buffered.flac',
      url: 'https://example.invalid/current-buffered.flac',
      hash: 'current-buffered-audio',
    );
    const next = AudioTrack(
      id: 'next-buffered',
      title: 'next-buffered.flac',
      url: 'https://example.invalid/next-buffered.flac',
      hash: 'current-buffered-audio',
    );
    service.updatePreloadThreshold(const Duration(seconds: 30));
    player.bufferedPosition = const Duration(seconds: 1);

    await service.updateQueue([current, next], autoplay: true);
    expect(downloader.targets, isEmpty);

    player.bufferedPosition = const Duration(seconds: 15);
    player.positions.add(player.position);
    expect(downloader.targets.last?.uri, Uri.parse(current.url));

    player.position = const Duration(minutes: 4, seconds: 40);
    player.bufferedPosition = const Duration(minutes: 4, seconds: 46);
    player.positions.add(player.position);
    // The hash matches the current target, but the URI changed, so starting
    // the next target still needs the full 15 seconds.
    expect(downloader.targets.last, isNull);

    player.bufferedPosition = const Duration(minutes: 4, seconds: 55);
    player.positions.add(player.position);
    expect(downloader.targets.last?.uri, Uri.parse(next.url));

    player.bufferedPosition = const Duration(minutes: 4, seconds: 46);
    player.positions.add(player.position);
    expect(downloader.targets.last?.uri, Uri.parse(next.url));

    player.bufferedPosition = const Duration(minutes: 4, seconds: 44);
    player.positions.add(player.position);
    expect(downloader.targets.last, isNull);

    player.bufferedPosition = const Duration(minutes: 4, seconds: 46);
    player.positions.add(player.position);
    expect(downloader.targets.last, isNull);

    player.bufferedPosition = const Duration(minutes: 4, seconds: 55);
    player.positions.add(player.position);
    expect(downloader.targets.last?.uri, Uri.parse(next.url));

    player.processingState = ProcessingState.buffering;
    player.emitPlayerState();
    await until(() => downloader.targets.last == null);
    expect(downloader.targets.last, isNull);

    player.processingState = ProcessingState.ready;
    player.bufferedPosition = const Duration(minutes: 4, seconds: 55);
    player.emitPlayerState();
    await until(() => downloader.targets.last?.uri == Uri.parse(next.url));
    expect(downloader.targets.last?.uri, Uri.parse(next.url));

    SpeculativeTransferCoordinator.instance.updateUserDownloads(
      active: 1,
      capacity: 1,
    );
    expect(downloader.targets.last, isNull);
    SpeculativeTransferCoordinator.instance.updateUserDownloads(
      active: 0,
      capacity: 1,
    );
    expect(downloader.targets.last?.uri, Uri.parse(next.url));

    player.position = const Duration(minutes: 4, seconds: 59);
    player.bufferedPosition = const Duration(minutes: 5);
    player.positions.add(player.position);
    expect(downloader.targets.last?.uri, Uri.parse(next.url));

    service.updatePreloadThreshold(null);
    expect(downloader.targets.last?.uri, Uri.parse(current.url));
  });

  test('Android service default preloads one minute ahead', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final androidPlayer = ControlledPlayer()
      ..bufferedPosition = const Duration(minutes: 5);
    final androidDownloader = _PendingCacheDownloader();
    final androidService = AudioPlayerService.forTesting(
      androidPlayer,
      sessionStore: MemorySessionStore(),
      cacheDownloader: androidDownloader,
    );
    addTearDown(androidService.dispose);
    const current = AudioTrack(
      id: 'current-default',
      title: 'current-default.flac',
      url: 'https://example.invalid/current-default.flac',
      hash: 'current-default-audio',
    );
    const next = AudioTrack(
      id: 'next-default',
      title: 'next-default.flac',
      url: 'https://example.invalid/next-default.flac',
      hash: 'next-default-audio',
    );

    await androidService.updateQueue([current, next], autoplay: true);
    androidPlayer.position = const Duration(minutes: 4);
    androidPlayer.positions.add(androidPlayer.position);

    expect(androidDownloader.targets.last?.hash, next.hash);
  });

  test(
    'Android local sources can preload without stream buffer headroom',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final localPath = '${root.path}/local.flac';
      await File(localPath).writeAsBytes([1, 2, 3]);
      final local = AudioTrack(
        id: 'local-buffered',
        title: 'local.flac',
        url: Uri.file(localPath).toString(),
      );
      const next = AudioTrack(
        id: 'next-local-buffered',
        title: 'next-local-buffered.flac',
        url: 'https://example.invalid/next-local-buffered.flac',
        hash: 'next-local-buffered-audio',
      );
      service.updatePreloadThreshold(const Duration(seconds: 10));

      await service.updateQueue([local, next], autoplay: true);
      player.position = const Duration(minutes: 4, seconds: 55);
      player.bufferedPosition = Duration.zero;
      player.positions.add(player.position);

      expect(downloader.targets.last?.hash, next.hash);
    },
  );

  test(
    'cache completion does not replace the source until the next load',
    () async {
      const track = AudioTrack(
        id: 'cached-later',
        title: 'cached-later.flac',
        url: 'https://example.invalid/cached-later.flac',
        hash: 'cached-later-audio',
      );

      await service
          .updateQueue([track], autoplay: true)
          .timeout(const Duration(seconds: 2));
      final remoteSource = player.audioSource;
      final partial = await CacheService.prepareAudioCacheTempFile(track.hash!);
      await partial.writeAsBytes([1, 2, 3, 4]);
      expect(
        await CacheService.finalizeAudioCacheFile(track.hash!, expectedSize: 4),
        isTrue,
      );

      downloader.complete(track.hash!);
      await Future<void>.delayed(Duration.zero);

      expect(player.audioSource, same(remoteSource));
      expect(player.loaded, [track.url]);

      await service.updateQueue([track]);
      final cachedPath = await CacheService.audioCacheFinalPath(track.hash!);
      expect(player.audioSource, isA<UriAudioSource>());
      expect((player.audioSource as UriAudioSource).uri.scheme, 'file');
      expect(player.source, cachedPath);
      expect(player.loaded, [track.url, cachedPath]);
    },
  );

  test('remote fallback does not wait for failed-cache invalidation', () async {
    const hash = 'failed-cache-fallback';
    final partial = await CacheService.prepareAudioCacheTempFile(hash);
    await partial.writeAsBytes([1, 2, 3, 4]);
    expect(
      await CacheService.finalizeAudioCacheFile(hash, expectedSize: 4),
      isTrue,
    );
    player.failFileAudioSource = true;
    downloader.invalidateGate = Completer<void>();
    const track = AudioTrack(
      id: 'failed-cache',
      title: 'failed-cache.flac',
      url: 'https://example.invalid/failed-cache.flac',
      hash: hash,
    );

    await service
        .updateQueue([track], autoplay: true)
        .timeout(const Duration(seconds: 2));

    expect(downloader.invalidationStarted, isTrue);
    expect(player.loaded, hasLength(1));
    expect(player.audioSource, isA<UriAudioSource>());
    expect((player.audioSource as UriAudioSource).uri.scheme, 'https');
    expect(player.playing, isTrue);
    downloader.invalidateGate!.complete();
  });

  test('a downloaded cache hit keeps local filename safety handling', () async {
    const hash = 'downloaded-local-source';
    const bytes = [1, 2, 3, 4];
    final partial = await CacheService.prepareAudioCacheTempFile(hash);
    await partial.writeAsBytes(bytes);
    expect(
      await CacheService.finalizeAudioCacheFile(hash, expectedSize: 4),
      isTrue,
    );

    final task = await DownloadService.instance.addTask(
      workId: 7654321,
      workTitle: 'Downloaded test',
      fileName: '试听音频.flac',
      downloadUrl: 'https://example.invalid/试听音频.flac',
      hash: hash,
    );
    downloadedTaskId = task.id;
    final track = AudioTrack(
      id: 'downloaded-track',
      title: '试听音频.flac',
      url: 'https://example.invalid/试听音频.flac',
      hash: hash,
      workId: task.workId,
    );

    await service.updateQueue([track]).timeout(const Duration(seconds: 2));

    final downloadedPath = await DownloadService.instance.getDownloadedFilePath(
      task.workId,
      hash,
    );
    expect(downloadedPath, isNotNull);
    expect(player.audioSource, isA<UriAudioSource>());
    expect((player.audioSource as UriAudioSource).uri.scheme, 'file');
    if (Platform.isAndroid) {
      expect(player.source, downloadedPath);
    } else {
      expect(player.source, isNot(downloadedPath));
      expect(player.source, contains('kikoflu_audio_temp'));
      expect(await File(player.source!).readAsBytes(), bytes);
    }
  });
}

class _PendingCacheDownloader extends AudioCacheDownloader {
  _PendingCacheDownloader() : super(files: CacheService.audioCacheFiles);

  final targets = <AudioCacheRequest?>[];
  final _completions = <Completer<bool>>[];
  Completer<void>? invalidateGate;
  bool invalidationStarted = false;

  @override
  Future<bool> setTarget(AudioCacheRequest? request) {
    targets.add(request);
    final completion = Completer<bool>();
    _completions.add(completion);
    return completion.future;
  }

  @override
  Future<void> invalidate(String hash) {
    invalidationStarted = true;
    final gate = invalidateGate;
    return gate == null ? super.invalidate(hash) : gate.future;
  }

  void complete(String hash, {bool result = true}) {
    final index = targets.indexWhere((target) => target?.hash == hash);
    if (index < 0) throw StateError('No pending cache request for $hash');
    final completion = _completions[index];
    if (!completion.isCompleted) completion.complete(result);
  }
}

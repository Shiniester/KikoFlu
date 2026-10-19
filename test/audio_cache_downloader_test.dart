import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/audio_cache_downloader.dart';
import 'package:kikoeru_flutter/src/services/audio_cache_files.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/remote_asset_cache.dart';
import 'package:kikoeru_flutter/src/services/resumable_file_transfer.dart';
import 'package:kikoeru_flutter/src/services/shared_http_client.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AudioCacheFiles files;
  final downloaders = <AudioCacheDownloader>[];
  final bytes = List<int>.generate(32, (index) => index);
  final target = AudioCacheRequest(
    uri: Uri.parse('https://example.test/audio.wav'),
    hash: 'work/audio',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await StorageService.initCritical(preferences: preferences);
    root = await Directory.systemTemp.createTemp('kiko-audio-cache-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    files = AudioCacheFiles(
      directoryProvider: () async => root,
      preferencesProvider: () async => preferences,
    );
  });

  tearDown(() async {
    for (final downloader in downloaders) {
      await downloader.dispose();
    }
    downloaders.clear();
    await root.delete(recursive: true);
  });

  AudioCacheDownloader createDownloader(
    _Transport transport, {
    AudioCacheFiles? cacheFiles,
    FutureOr<void> Function()? onCacheCompleted,
  }) {
    final downloader = AudioCacheDownloader(
      files: cacheFiles ?? files,
      transfer: ResumableFileTransfer(transport: transport),
      headersProvider: () => {'Cookie': 'session=test'},
      onCacheCompleted: onCacheCompleted,
      logger: (_) {},
    );
    downloaders.add(downloader);
    return downloader;
  }

  test(
    'publishes only complete files and skips already cached audio',
    () async {
      final transport = _Transport(bytes);
      final downloader = createDownloader(transport);
      expect(await downloader.setTarget(target), isTrue);
      final path = await files.completedPath(target.hash);
      expect(await File(path!).readAsBytes(), bytes);
      expect(await (await files.partialFile(target.hash)).exists(), isFalse);
      expect(transport.requests.single.headers['Cookie'], 'session=test');
      expect(await downloader.setTarget(target), isTrue);
      expect(transport.requests, hasLength(1));
    },
  );

  test('deduplicates a target and resumes its cancelled prefix', () async {
    final transport = _Transport(bytes, holdBodyAfter: 8);
    final downloader = createDownloader(transport);
    final first = downloader.setTarget(target);
    expect(identical(first, downloader.setTarget(target)), isTrue);
    await transport.bodyHeld.future;
    final partial = await files.partialFile(target.hash);
    expect(await partial.readAsBytes(), bytes.sublist(0, 8));
    expect(AudioCacheFiles.isCachePathActive(partial.path), isTrue);
    expect(await files.completedPath(target.hash), isNull);
    await downloader.setTarget(null);
    expect(await first, isFalse);
    expect(AudioCacheFiles.isCachePathActive(partial.path), isFalse);

    await downloader.dispose();
    final resumedTransport = _Transport(bytes);
    final resumed = createDownloader(resumedTransport);
    expect(await resumed.setTarget(target), isTrue);
    expect(resumedTransport.requests.single.headers['Range'], 'bytes=8-');
    expect(
      await File((await files.completedPath(target.hash))!).readAsBytes(),
      bytes,
    );
  });

  test(
    'cancel and replace retains the file-close barrier and newest target',
    () async {
      final transport = _Transport(bytes, holdHeaders: true);
      final downloader = createDownloader(transport);
      final first = downloader.setTarget(target);
      await transport.headersHeld.future;
      final cancelling = downloader.setTarget(null);
      final superseded = downloader.setTarget(
        AudioCacheRequest(
          uri: Uri.parse('https://example.test/b.wav'),
          hash: 'b',
        ),
      );
      final newest = AudioCacheRequest(
        uri: Uri.parse('https://example.test/c.wav'),
        hash: 'c',
      );
      final last = downloader.setTarget(newest);
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, hasLength(1));
      transport.releaseHeaders.complete();
      expect(await first, isFalse);
      expect(await cancelling, isFalse);
      expect(await superseded, isFalse);
      expect(await last, isTrue);
      expect(transport.requests.map((request) => request.uri), [
        target.uri,
        newest.uri,
      ]);
      expect(await files.completedPath('b'), isNull);
    },
  );

  test(
    'a short response stays partial and a later target resumes it',
    () async {
      final transport = _Transport(bytes, truncateAt: 8);
      final downloader = createDownloader(transport);
      expect(await downloader.setTarget(target), isFalse);
      expect(await files.completedPath(target.hash), isNull);
      final partial = await files.partialFile(target.hash);
      expect(await partial.readAsBytes(), bytes.sublist(0, 8));
      expect(AudioCacheFiles.isCachePathActive(partial.path), isFalse);
      expect(await downloader.setTarget(target), isTrue);
      expect(transport.requests.last.headers['Range'], 'bytes=8-');
      expect(
        await File((await files.completedPath(target.hash))!).readAsBytes(),
        bytes,
      );
    },
  );

  test('maintenance failure does not discard a completed cache', () async {
    final downloader = createDownloader(
      _Transport(bytes),
      onCacheCompleted: () => throw StateError('Maintenance unavailable'),
    );
    expect(await downloader.setTarget(target), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(await files.completedPath(target.hash), isNotNull);
  });

  test('clear cancels downloads and retains a leased playback file', () async {
    final cachedFiles = CacheService.audioCacheFiles;
    final partial = await cachedFiles.partialFile('playing', create: true);
    await partial.writeAsBytes(bytes);
    expect(
      await cachedFiles.finalize('playing', expectedSize: bytes.length),
      isTrue,
    );
    final path = (await cachedFiles.completedPath('playing'))!;
    final lease = AudioCacheFiles.holdCacheFile(path);
    final secondLease = AudioCacheFiles.holdCacheFile(path);
    addTearDown(lease.release);
    addTearDown(secondLease.release);
    final transport = _Transport(bytes, holdBodyAfter: 8);
    final downloader = createDownloader(transport, cacheFiles: cachedFiles);
    final downloading = downloader.setTarget(target);
    await transport.bodyHeld.future;

    await CacheService.clearAudioCache();
    expect(await downloading, isFalse);
    expect(
      await (await cachedFiles.partialFile(target.hash)).exists(),
      isFalse,
    );
    expect(await cachedFiles.completedPath('playing'), path);
    lease.release();
    lease.release();
    expect(AudioCacheFiles.isCachePathActive(path), isTrue);
    secondLease.release();
    await CacheService.clearAudioCache();
    expect(await File(path).exists(), isFalse);
  });

  test('invalidation cancels the writer before removing its prefix', () async {
    final transport = _Transport(bytes, holdBodyAfter: 8);
    final downloader = createDownloader(transport);
    final downloading = downloader.setTarget(target);
    await transport.bodyHeld.future;
    await downloader.invalidate(target.hash);
    expect(await downloading, isFalse);
    expect(await (await files.partialFile(target.hash)).exists(), isFalse);
    expect(await files.completedPath(target.hash), isNull);
  });

  test(
    'replacement waits for invalidation without losing its new file',
    () async {
      final transport = _Transport(bytes, holdHeaders: true);
      final downloader = createDownloader(transport);
      final first = downloader.setTarget(target);
      await transport.headersHeld.future;
      final invalidating = downloader.invalidate(target.hash);
      final replacement = downloader.setTarget(target);
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, hasLength(1));

      transport.releaseHeaders.complete();
      expect(await first, isFalse);
      await invalidating;
      expect(await replacement, isTrue);
      expect(transport.requests, hasLength(2));
      expect(
        await File((await files.completedPath(target.hash))!).readAsBytes(),
        bytes,
      );
    },
  );

  test(
    'expiry lookup preserves owned files until their leases are released',
    () async {
      final partial = await files.partialFile('expired', create: true);
      await partial.writeAsBytes(bytes);
      expect(
        await files.finalize('expired', expectedSize: bytes.length),
        isTrue,
      );
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(
        AudioCacheFiles.completeMetadataKey('expired'),
        DateTime.now()
            .subtract(const Duration(days: 31))
            .millisecondsSinceEpoch,
      );
      final completed = await files.finalFile('expired');
      final lease = AudioCacheFiles.holdCacheFile(completed.path);
      expect(await files.completedPath('expired'), completed.path);
      lease.release();
      expect(await files.completedPath('expired'), isNull);

      final oldPartial = await files.partialFile('old-prefix', create: true);
      await oldPartial.writeAsBytes(bytes);
      await oldPartial.setLastModified(
        DateTime.now().subtract(const Duration(days: 31)),
      );
      final prefixLease = AudioCacheFiles.holdCacheFile(oldPartial.path);
      await files.removeExpiredPartial('old-prefix');
      expect(await oldPartial.exists(), isTrue);
      prefixLease.release();
      await files.removeExpiredPartial('old-prefix');
      expect(await oldPartial.exists(), isFalse);
    },
  );

  test('native and background requests share the existing media headers', () {
    final official = mediaRequestHeaders(
      Uri.parse('https://api.asmr.one/api/media/stream/hash'),
      {'Cookie': 'session=test', 'ACCEPT-ENCODING': 'gzip'},
      forceIdentityEncoding: true,
    );
    expect(official['Cookie'], 'session=test');
    expect(official[HttpHeaders.userAgentHeader], contains('Mozilla'));
    expect(official[HttpHeaders.refererHeader], 'https://www.asmr.one/');
    expect(official['origin'], 'https://www.asmr.one');
    expect(official[HttpHeaders.acceptEncodingHeader], 'identity');
    expect(official.containsKey('ACCEPT-ENCODING'), isFalse);
    final custom = mediaRequestHeaders(
      Uri.parse('https://self-hosted.test/track.wav'),
      {'User-Agent': 'Custom'},
    );
    expect(custom['User-Agent'], 'Custom');
    expect(custom.containsKey(HttpHeaders.userAgentHeader), isFalse);
    expect(custom.containsKey(HttpHeaders.refererHeader), isFalse);
  });
}

class _Transport implements RemoteAssetTransport {
  _Transport(
    this.bytes, {
    this.holdBodyAfter,
    this.holdHeaders = false,
    this.truncateAt,
  });

  final List<int> bytes;
  final int? holdBodyAfter;
  final bool holdHeaders;
  final int? truncateAt;
  final requests = <RemoteAssetTransportRequest>[];
  final bodyHeld = Completer<void>();
  final headersHeld = Completer<void>();
  final releaseHeaders = Completer<void>();

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest request) async {
    requests.add(request);
    final first = requests.length == 1;
    if (first && holdHeaders) {
      headersHeld.complete();
      await releaseHeaders.future;
    }
    final range = request.headers['Range'];
    final start = range == null
        ? 0
        : int.parse(range.substring(6, range.length - 1));
    return RemoteAssetResponse(
      statusCode: start == 0 ? HttpStatus.ok : HttpStatus.partialContent,
      contentLength: bytes.length - start,
      headers: {
        if (start > 0)
          'content-range': 'bytes $start-${bytes.length - 1}/${bytes.length}',
      },
      stream: _body(request, start, first),
    );
  }

  Stream<List<int>> _body(
    RemoteAssetTransportRequest request,
    int start,
    bool first,
  ) async* {
    if (first && holdBodyAfter != null) {
      yield bytes.sublist(start, holdBodyAfter);
      bodyHeld.complete();
      await request.cancellation.whenCancelled;
      throw const HttpException('Cancelled');
    }
    yield bytes.sublist(
      start,
      first ? truncateAt ?? bytes.length : bytes.length,
    );
  }
}

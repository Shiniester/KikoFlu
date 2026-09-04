import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// ignore_for_file: experimental_member_use

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/audio_cache_files.dart';
import 'package:kikoeru_flutter/src/services/audio_stream_cache.dart';
import 'package:kikoeru_flutter/src/services/caching_stream_audio_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final realHttpClient = HttpClient();
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDownAll(() => realHttpClient.close(force: true));

  late Directory cacheDirectory;
  late AudioCacheFiles files;
  AudioStreamCache? cache;

  final sourceBytes = Uint8List.fromList(
    List<int>.generate(160, (index) => (index * 17) % 256),
  );
  final transfer = AudioTransferRequest(
    uri: Uri.parse('https://example.test/audio.flac'),
    hash: 'work/audio-hash',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    cacheDirectory = await Directory.systemTemp.createTemp(
      'kikoeru_audio_stream_cache_test_',
    );
    files = AudioCacheFiles(
      directoryProvider: () async => cacheDirectory,
      preferencesProvider: () async => preferences,
    );
  });

  tearDown(() async {
    await cache?.dispose();
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
  });

  AudioStreamCache createCache(_MemoryAudioRangeTransport transport) {
    final created = AudioStreamCache(
      files: files,
      transport: transport,
      logger: (_) {},
    );
    cache = created;
    return created;
  }

  test(
    'hands a preloaded prefix to playback without downloading it twice',
    () async {
      final transport = _MemoryAudioRangeTransport(
        sourceBytes,
        pauseFirstRequestAfter: 32,
      );
      final streamCache = createCache(transport);

      final preload = streamCache.setPreloadTarget(transfer);
      await transport.firstRequestPaused;
      final partial = await files.partialFile(transfer.hash);
      expect(await partial.length(), 32);
      expect(AudioStreamCache.isCachePathActive(partial.path), isTrue);

      final target = await streamCache.preparePlayback(transfer);
      expect(await preload, isFalse);
      expect(target, isA<AudioStreamPlaybackTarget>());
      expect(await partial.length(), 32);

      final source = CachingStreamAudioSource(
        cache: streamCache,
        transfer: transfer,
      );
      final response = await source.request();
      expect(await _collect(response.stream), sourceBytes);

      expect(
        transport.requests.map((request) => request.start),
        orderedEquals([0, 32]),
      );
      expect(
        transport.requests
            .map((request) => request.deliveredBytes)
            .reduce((left, right) => left + right),
        sourceBytes.length,
      );
      expect(AudioStreamCache.isCachePathActive(partial.path), isFalse);
    },
  );

  test(
    'resumes an interrupted preload after the cache module is recreated',
    () async {
      final firstTransport = _MemoryAudioRangeTransport(
        sourceBytes,
        pauseFirstRequestAfter: 40,
      );
      final firstCache = createCache(firstTransport);
      final preload = firstCache.setPreloadTarget(transfer);
      await firstTransport.firstRequestPaused;
      await firstCache.setPreloadTarget(null);
      expect(await preload, isFalse);
      expect(await (await files.partialFile(transfer.hash)).length(), 40);
      await firstCache.dispose();

      final secondTransport = _MemoryAudioRangeTransport(sourceBytes);
      final secondCache = AudioStreamCache(
        files: files,
        transport: secondTransport,
        logger: (_) {},
      );
      cache = secondCache;
      expect(await secondCache.setPreloadTarget(transfer), isTrue);

      expect(secondTransport.requests.single.start, 40);
      final completed = await files.completedPath(transfer.hash);
      expect(completed, isNotNull);
      expect(await File(completed!).readAsBytes(), sourceBytes);
    },
  );

  test('resumes streaming playback from its retained prefix', () async {
    final transport = _MemoryAudioRangeTransport(sourceBytes);
    final streamCache = createCache(transport);
    final firstResponse = await streamCache.openRange(transfer);
    final firstPlayback = StreamIterator<List<int>>(firstResponse.stream);

    expect(await firstPlayback.moveNext(), isTrue);
    expect(await firstPlayback.moveNext(), isTrue);
    expect(await firstPlayback.moveNext(), isTrue);
    await firstPlayback.cancel();

    final partial = await files.partialFile(transfer.hash);
    expect(await partial.length(), 48);
    final resumedResponse = await streamCache.openRange(transfer);
    expect(await _collect(resumedResponse.stream), sourceBytes);
    expect(
      transport.requests.map((request) => request.start),
      orderedEquals([0, 48]),
    );
  });

  test('a completed playback lease keeps its cache path active', () async {
    final completed = await files.finalFile(transfer.hash);
    await completed.writeAsBytes(sourceBytes);

    final lease = AudioStreamCache.holdCacheFile(completed.path);
    expect(AudioStreamCache.isCachePathActive(completed.path), isTrue);

    lease.release();
    lease.release();
    expect(AudioStreamCache.isCachePathActive(completed.path), isFalse);
  });

  test(
    'serves a range inside the cached prefix without network traffic',
    () async {
      final transport = _MemoryAudioRangeTransport(sourceBytes);
      final streamCache = createCache(transport);
      final partial = await files.partialFile(transfer.hash, create: true);
      await partial.writeAsBytes(sourceBytes.sublist(0, 64));
      await files.writePartialMetadata(
        transfer.hash,
        sourceLength: sourceBytes.length,
        contentType: 'audio/flac',
      );

      final response = await streamCache.openRange(transfer, 12, 28);

      expect(await _collect(response.stream), sourceBytes.sublist(12, 28));
      expect(response.sourceLength, sourceBytes.length);
      expect(response.offset, 12);
      expect(response.contentLength, 16);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'passes a seek beyond the prefix through without corrupting the prefix',
    () async {
      final transport = _MemoryAudioRangeTransport(sourceBytes);
      final streamCache = createCache(transport);
      final partial = await files.partialFile(transfer.hash, create: true);
      await partial.writeAsBytes(sourceBytes.sublist(0, 48));
      await files.writePartialMetadata(
        transfer.hash,
        sourceLength: sourceBytes.length,
      );

      final response = await streamCache.openRange(transfer, 80, 104);

      expect(await _collect(response.stream), sourceBytes.sublist(80, 104));
      expect(await partial.length(), 48);
      expect(await partial.readAsBytes(), sourceBytes.sublist(0, 48));
      expect(transport.requests.single, _RangeRequest(80, 104));
    },
  );

  test('deduplicates simultaneous preloads for the same audio', () async {
    final transport = _MemoryAudioRangeTransport(
      sourceBytes,
      pauseFirstRequestAfter: 24,
    );
    final streamCache = createCache(transport);

    final first = streamCache.setPreloadTarget(transfer);
    final second = streamCache.setPreloadTarget(transfer);
    expect(identical(first, second), isTrue);
    await transport.firstRequestPaused;
    expect(transport.requests, hasLength(1));

    await streamCache.setPreloadTarget(null);
    expect(await first, isFalse);
    expect(await second, isFalse);
    expect(await (await files.partialFile(transfer.hash)).length(), 24);
  });

  test(
    'switching preload targets preserves the cancelled target prefix',
    () async {
      final transport = _MemoryAudioRangeTransport(
        sourceBytes,
        pauseFirstRequestAfter: 32,
      );
      final streamCache = createCache(transport);
      final stalePreload = streamCache.setPreloadTarget(transfer);
      await transport.firstRequestPaused;
      final replacement = AudioTransferRequest(
        uri: Uri.parse('https://example.test/replacement.flac'),
        hash: 'work/replacement-hash',
      );

      final replacementResult = streamCache.setPreloadTarget(replacement);

      expect(await stalePreload, isFalse);
      expect(await replacementResult, isTrue);
      expect(await (await files.partialFile(transfer.hash)).length(), 32);
      expect(transport.requests.map((request) => request.start), [0, 0]);
    },
  );

  test('completed cache replay needs no origin audio bytes', () async {
    final transport = _MemoryAudioRangeTransport(sourceBytes);
    final streamCache = createCache(transport);

    expect(await streamCache.setPreloadTarget(transfer), isTrue);
    expect(transport.requests, hasLength(1));

    final target = await streamCache.preparePlayback(transfer);
    expect(target, isA<AudioFilePlaybackTarget>());
    final path = (target as AudioFilePlaybackTarget).path;
    expect(await File(path).readAsBytes(), sourceBytes);
    expect(transport.requests, hasLength(1));
  });

  test('safely restarts from zero when the origin ignores Range', () async {
    final transport = _MemoryAudioRangeTransport(
      sourceBytes,
      supportsRanges: false,
    );
    final streamCache = createCache(transport);
    final partial = await files.partialFile(transfer.hash, create: true);
    await partial.writeAsBytes(sourceBytes.sublist(0, 36));
    await files.writePartialMetadata(
      transfer.hash,
      sourceLength: sourceBytes.length,
    );

    final response = await streamCache.openRange(transfer);

    expect(await _collect(response.stream), sourceBytes);
    expect(transport.requests.single.start, 36);
    final target = await streamCache.preparePlayback(transfer);
    expect(target, isA<AudioFilePlaybackTarget>());
    expect(
      await File((target as AudioFilePlaybackTarget).path).readAsBytes(),
      sourceBytes,
    );
  });

  test(
    'Range-ignoring origin still returns the requested seek bytes',
    () async {
      final transport = _MemoryAudioRangeTransport(
        sourceBytes,
        supportsRanges: false,
      );
      final streamCache = createCache(transport);
      final partial = await files.partialFile(transfer.hash, create: true);
      await partial.writeAsBytes(sourceBytes.sublist(0, 48));
      await files.writePartialMetadata(
        transfer.hash,
        sourceLength: sourceBytes.length,
      );

      final response = await streamCache.openRange(transfer, 80, 104);

      expect(await _collect(response.stream), sourceBytes.sublist(80, 104));
      expect(response.offset, 80);
      expect(response.contentLength, 24);
      expect(await partial.length(), 104);
      expect(await partial.readAsBytes(), sourceBytes.sublist(0, 104));
    },
  );

  test('invalid Content-Range removes an inconsistent prefix', () async {
    final transport = _MemoryAudioRangeTransport(
      sourceBytes,
      malformedContentRange: true,
    );
    final streamCache = createCache(transport);
    final partial = await files.partialFile(transfer.hash, create: true);
    await partial.writeAsBytes(sourceBytes.sublist(0, 20));
    await files.writePartialMetadata(
      transfer.hash,
      sourceLength: sourceBytes.length,
    );

    await expectLater(streamCache.openRange(transfer), throwsFormatException);
    expect(await partial.exists(), isFalse);
    expect(await files.readPartialMetadata(transfer.hash), isNull);
  });

  test(
    'a short response preserves its valid prefix for another resume',
    () async {
      final transport = _MemoryAudioRangeTransport(sourceBytes, shortBy: 12);
      final streamCache = createCache(transport);

      expect(await streamCache.setPreloadTarget(transfer), isFalse);

      final partial = await files.partialFile(transfer.hash);
      expect(await partial.length(), sourceBytes.length - 12);
      expect(
        await partial.readAsBytes(),
        sourceBytes.sublist(0, sourceBytes.length - 12),
      );
      expect(await files.completedPath(transfer.hash), isNull);
    },
  );

  test('finalizes a complete full response without Content-Length', () async {
    final transport = _MemoryAudioRangeTransport(
      sourceBytes,
      omitContentLength: true,
    );
    final streamCache = createCache(transport);

    final response = await streamCache.openRange(transfer);

    expect(response.sourceLength, isNull);
    expect(await _collect(response.stream), sourceBytes);
    final target = await streamCache.preparePlayback(transfer);
    expect(target, isA<AudioFilePlaybackTarget>());
    expect(
      await File((target as AudioFilePlaybackTarget).path).readAsBytes(),
      sourceBytes,
    );
  });

  test('HTTP adapter sends exact Range and caller headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<(String?, String?, String?)>();
    server.listen((request) async {
      received.complete((
        request.headers.value(HttpHeaders.rangeHeader),
        request.headers.value(HttpHeaders.cookieHeader),
        request.headers.value(HttpHeaders.acceptEncodingHeader),
      ));
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 5-14/160')
        ..headers.contentLength = 10
        ..add(sourceBytes.sublist(5, 15));
      await request.response.close();
    });
    final transport = HttpAudioRangeTransport(client: realHttpClient);

    final response = await transport.open(
      uri: Uri.parse('http://${server.address.host}:${server.port}/audio'),
      start: 5,
      end: 15,
      headers: const {'Cookie': 'session=test'},
      cancellation: AudioTransferCancellation(),
    );

    expect(await _collect(response.stream), sourceBytes.sublist(5, 15));
    expect(await received.future, ('bytes=5-14', 'session=test', 'identity'));
  });
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

class _MemoryAudioRangeTransport implements AudioRangeTransport {
  _MemoryAudioRangeTransport(
    this.bytes, {
    this.supportsRanges = true,
    this.pauseFirstRequestAfter,
    this.malformedContentRange = false,
    this.shortBy = 0,
    this.omitContentLength = false,
  });

  final Uint8List bytes;
  final bool supportsRanges;
  final int? pauseFirstRequestAfter;
  final bool malformedContentRange;
  final int shortBy;
  final bool omitContentLength;
  final List<_RangeRequest> requests = [];
  final Completer<void> _firstRequestPaused = Completer<void>();

  Future<void> get firstRequestPaused => _firstRequestPaused.future;

  @override
  Future<AudioRangeResponse> open({
    required Uri uri,
    required int start,
    int? end,
    required Map<String, String> headers,
    required AudioTransferCancellation cancellation,
  }) async {
    final request = _RangeRequest(start, end);
    requests.add(request);
    final hasRange = start != 0 || end != null;
    final rangeHonored = supportsRanges && hasRange;
    final responseStart = rangeHonored ? start : 0;
    final declaredEnd = rangeHonored
        ? math.min(end ?? bytes.length, bytes.length)
        : bytes.length;
    final deliveredEnd = math.max(responseStart, declaredEnd - shortBy);
    final requestIndex = requests.length - 1;
    final stream =
        _chunks(
          responseStart,
          deliveredEnd,
          cancellation,
          pauseAfter: requestIndex == 0 ? pauseFirstRequestAfter : null,
        ).map((chunk) {
          request.deliveredBytes += chunk.length;
          return chunk;
        });

    return AudioRangeResponse(
      statusCode: rangeHonored ? HttpStatus.partialContent : HttpStatus.ok,
      contentLength: omitContentLength ? null : declaredEnd - responseStart,
      contentRange: rangeHonored
          ? malformedContentRange
                ? 'bytes 0-${declaredEnd - 1}/${bytes.length}'
                : 'bytes $responseStart-${declaredEnd - 1}/${bytes.length}'
          : null,
      contentType: 'audio/flac',
      stream: stream,
    );
  }

  Stream<List<int>> _chunks(
    int start,
    int end,
    AudioTransferCancellation cancellation, {
    int? pauseAfter,
  }) async* {
    var cursor = start;
    while (cursor < end && !cancellation.isCancelled) {
      var next = math.min(cursor + 16, end);
      if (pauseAfter != null && cursor < pauseAfter && next > pauseAfter) {
        next = pauseAfter;
      }
      yield bytes.sublist(cursor, next);
      cursor = next;
      if (pauseAfter != null && cursor >= pauseAfter) {
        if (!_firstRequestPaused.isCompleted) _firstRequestPaused.complete();
        await cancellation.whenCancelled;
        return;
      }
    }
  }
}

class _RangeRequest {
  _RangeRequest(this.start, this.end);

  final int start;
  final int? end;
  int deliveredBytes = 0;

  @override
  bool operator ==(Object other) =>
      other is _RangeRequest && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'RangeRequest($start, $end)';
}

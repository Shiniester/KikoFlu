import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as cm;
import 'package:kikoeru_flutter/src/services/remote_asset_cache.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'kikoflu_remote_asset_cache_test_',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('canonical URLs preserve repeated non-auth query parameters', () {
    final first = RemoteAssetKey.canonicalUri(
      Uri.parse(
        'https://example.com/api/works?tag=2&token=secret&sort=asc&tag=1',
      ),
    );
    final reordered = RemoteAssetKey.canonicalUri(
      Uri.parse(
        'https://example.com/api/works?sort=asc&tag=1&tag=2&token=rotated',
      ),
    );
    final missingTag = RemoteAssetKey.canonicalUri(
      Uri.parse('https://example.com/api/works?sort=asc&tag=1'),
    );

    expect(first, reordered);
    expect(first, isNot(missingTag));
    expect(first, isNot(contains('secret')));
  });

  test('concurrent callers share one response body', () async {
    final transport = _RecordingTransport(const [
      1,
      2,
      3,
      4,
      5,
    ], responseDelay: const Duration(milliseconds: 10));
    final cache = FileRemoteAssetCache(
      directoryProvider: () async => tempDirectory,
      transport: transport,
    );
    addTearDown(cache.dispose);
    final request = RemoteAssetRequest(
      uri: Uri.parse('https://example.com/api/cover/42?token=first'),
      key: const RemoteAssetKey(
        serverScope: 'https://example.com|alice',
        kind: RemoteAssetKind.workCover,
        identity: '42',
      ),
      fileExtension: 'jpg',
    );

    final first = cache.acquire(request);
    final second = cache.acquire(request);
    final files = await Future.wait([first.file, second.file]);

    expect(transport.requests, hasLength(1));
    expect(await files.first.readAsBytes(), const [1, 2, 3, 4, 5]);
    expect(await files.last.readAsBytes(), const [1, 2, 3, 4, 5]);

    await first.release();
    await second.release();

    final cached = cache.acquire(request);
    expect(await (await cached.file).readAsBytes(), const [1, 2, 3, 4, 5]);
    expect(transport.requests, hasLength(1));
    await cached.release();
  });

  test('a visible lease takes over a released speculative transfer', () async {
    final transport = _RecordingTransport(const [
      5,
      4,
      3,
      2,
      1,
    ], responseDelay: const Duration(milliseconds: 20));
    final cache = FileRemoteAssetCache(
      directoryProvider: () async => tempDirectory,
      transport: transport,
    );
    addTearDown(cache.dispose);
    final request = RemoteAssetRequest(
      uri: Uri.parse('https://example.com/api/cover/9'),
      key: const RemoteAssetKey(
        serverScope: 'https://example.com|alice',
        kind: RemoteAssetKind.workCover,
        identity: '9',
      ),
      fileExtension: 'jpg',
    );

    final speculative = cache.acquire(request, speculative: true);
    final visible = cache.acquire(request);
    await speculative.release();

    expect(await (await visible.file).readAsBytes(), const [5, 4, 3, 2, 1]);
    expect(transport.requests, hasLength(1));
    await visible.release();
  });

  test(
    'an interrupted binary response resumes after its saved prefix',
    () async {
      final transport = _CallbackTransport((request, index) {
        if (index == 0) {
          return RemoteAssetResponse(
            statusCode: HttpStatus.ok,
            contentLength: 5,
            headers: const {},
            stream: Stream.value(const [1, 2]),
          );
        }
        return RemoteAssetResponse(
          statusCode: HttpStatus.partialContent,
          contentLength: 3,
          headers: const {'content-range': 'bytes 2-4/5'},
          stream: Stream.value(const [3, 4, 5]),
        );
      });
      final cache = FileRemoteAssetCache(
        directoryProvider: () async => tempDirectory,
        transport: transport,
      );
      addTearDown(cache.dispose);
      final request = RemoteAssetRequest(
        uri: Uri.parse('https://example.com/files/book.pdf'),
        key: const RemoteAssetKey(
          serverScope: 'https://example.com|alice',
          kind: RemoteAssetKind.document,
          identity: 'pdf-hash',
        ),
        fileExtension: 'pdf',
      );

      final interrupted = cache.acquire(request);
      await expectLater(interrupted.file, throwsA(isA<HttpException>()));
      await interrupted.release();

      final resumed = cache.acquire(request);
      final file = await resumed.file;
      expect(transport.requests, hasLength(2));
      expect(transport.requests.last.headers['Range'], 'bytes=2-');
      expect(transport.requests.last.headers['Accept-Encoding'], 'identity');
      expect(await file.readAsBytes(), const [1, 2, 3, 4, 5]);
      await resumed.release();
    },
  );

  test('a prefix with corrupt metadata restarts from byte zero', () async {
    final transport = _CallbackTransport((request, index) {
      if (index == 0) {
        return RemoteAssetResponse(
          statusCode: HttpStatus.ok,
          contentLength: 5,
          headers: const {'etag': '"document-v1"'},
          stream: Stream.value(const [1, 2]),
        );
      }
      expect(request.headers, isNot(contains('Range')));
      expect(request.headers, isNot(contains('If-Range')));
      return RemoteAssetResponse(
        statusCode: HttpStatus.ok,
        contentLength: 5,
        headers: const {'etag': '"document-v2"'},
        stream: Stream.value(const [9, 8, 7, 6, 5]),
      );
    });
    final cache = FileRemoteAssetCache(
      directoryProvider: () async => tempDirectory,
      transport: transport,
    );
    addTearDown(cache.dispose);
    final request = RemoteAssetRequest(
      uri: Uri.parse('https://example.com/files/corrupt-metadata.pdf'),
      key: const RemoteAssetKey(
        serverScope: 'https://example.com|alice',
        kind: RemoteAssetKind.document,
        identity: 'corrupt-partial-metadata',
      ),
      fileExtension: 'pdf',
    );

    final interrupted = cache.acquire(request);
    await expectLater(interrupted.file, throwsA(isA<HttpException>()));
    await interrupted.release();

    final metadata = await tempDirectory
        .list()
        .where(
          (entity) =>
              entity is File && entity.path.endsWith('.part.metadata.json'),
        )
        .cast<File>()
        .single;
    await metadata.writeAsString('{invalid');

    final restarted = cache.acquire(request);
    expect(await (await restarted.file).readAsBytes(), const [9, 8, 7, 6, 5]);
    expect(transport.requests, hasLength(2));
    await restarted.release();
  });

  test(
    'a changed auth token revalidates the stable key without a body',
    () async {
      final transport = _CallbackTransport((request, index) {
        if (index == 0) {
          return RemoteAssetResponse(
            statusCode: HttpStatus.ok,
            contentLength: 3,
            headers: const {'etag': '"cover-v1"', 'cache-control': 'max-age=0'},
            stream: Stream.value(const [7, 8, 9]),
          );
        }
        return const RemoteAssetResponse(
          statusCode: HttpStatus.notModified,
          contentLength: 0,
          headers: {'cache-control': 'max-age=3600'},
          stream: Stream.empty(),
        );
      });
      final cache = FileRemoteAssetCache(
        directoryProvider: () async => tempDirectory,
        transport: transport,
      );
      addTearDown(cache.dispose);
      const key = RemoteAssetKey(
        serverScope: 'https://example.com|alice',
        kind: RemoteAssetKind.workCover,
        identity: '42',
      );

      final first = cache.acquire(
        RemoteAssetRequest(
          uri: Uri.parse('https://example.com/api/cover/42?token=first'),
          key: key,
          fileExtension: 'jpg',
        ),
      );
      final original = await first.file;
      await first.release();

      final second = cache.acquire(
        RemoteAssetRequest(
          uri: Uri.parse('https://example.com/api/cover/42?token=second'),
          key: key,
          fileExtension: 'jpg',
          forceRevalidate: true,
        ),
      );
      final revalidated = await second.file;

      expect(transport.requests, hasLength(2));
      expect(transport.requests.last.headers['If-None-Match'], '"cover-v1"');
      expect(revalidated.path, original.path);
      expect(await revalidated.readAsBytes(), const [7, 8, 9]);
      await second.release();
    },
  );

  test('no-store asset exists only for the lifetime of its lease', () async {
    final transport = _RecordingTransport(
      const [4, 2],
      headers: const {'cache-control': 'no-store'},
    );
    final cache = FileRemoteAssetCache(
      directoryProvider: () async => tempDirectory,
      transport: transport,
    );
    addTearDown(cache.dispose);
    const key = RemoteAssetKey(
      serverScope: 'https://example.com|alice',
      kind: RemoteAssetKind.contentImage,
      identity: 'private-image',
    );
    final request = RemoteAssetRequest(
      uri: Uri.parse('https://example.com/private.png'),
      key: key,
      fileExtension: 'png',
    );

    final first = cache.acquire(request);
    final firstFile = await first.file;
    expect(await firstFile.exists(), isTrue);
    expect(await cache.find(key), isNull);
    await first.release();
    expect(await firstFile.exists(), isFalse);

    final second = cache.acquire(request);
    await second.file;
    expect(transport.requests, hasLength(2));
    await second.release();
  });

  test(
    'image cache manager keeps no-store return values readable for callers',
    () async {
      const bytes = [4, 2];
      final transport = _RecordingTransport(
        bytes,
        headers: const {'cache-control': 'no-store'},
      );
      final cache = FileRemoteAssetCache(
        directoryProvider: () async => tempDirectory,
        transport: transport,
      );
      final manager = RemoteAssetImageCacheManager(cache: cache);
      addTearDown(manager.dispose);
      addTearDown(cache.dispose);

      final downloaded = await manager.downloadFile(
        'https://example.com/private-one.png',
        key: 'work_cover_1',
      );
      final single = await manager.getSingleFile(
        'https://example.com/private-two.png',
        key: 'work_cover_2',
      );
      final streamedResponses = await manager
          .getFileStream(
            'https://example.com/private-three.png',
            key: 'work_cover_3',
          )
          .toList();
      final streamed = streamedResponses.whereType<cm.FileInfo>().single.file;

      expect(await downloaded.file.exists(), isTrue);
      expect(await downloaded.file.readAsBytes(), bytes);
      expect(await single.exists(), isTrue);
      expect(await single.readAsBytes(), bytes);
      expect(await streamed.exists(), isTrue);
      expect(await streamed.readAsBytes(), bytes);
      await manager.emptyCache();
      expect(await downloaded.file.exists(), isFalse);
      expect(await single.exists(), isFalse);
      expect(await streamed.exists(), isFalse);
    },
  );

  test('capacity cleanup skips files held by active leases', () async {
    final transport = _RecordingTransport(const [9, 8, 7]);
    final cache = FileRemoteAssetCache(
      directoryProvider: () async => tempDirectory,
      transport: transport,
    );
    addTearDown(cache.dispose);
    const key = RemoteAssetKey(
      serverScope: 'https://example.com|alice',
      kind: RemoteAssetKind.document,
      identity: 'active-document',
    );
    final lease = cache.acquire(
      RemoteAssetRequest(
        uri: Uri.parse('https://example.com/document.pdf'),
        key: key,
        fileExtension: 'pdf',
      ),
    );
    final file = await lease.file;

    await cache.clearInactive();
    expect(await file.exists(), isTrue);

    await lease.release();
    expect(await file.exists(), isFalse);
    await cache.clearInactive();
    expect(await file.exists(), isFalse);
  });

  test(
    'an origin that ignores Range safely replaces the retained prefix',
    () async {
      final transport = _CallbackTransport((request, index) {
        return RemoteAssetResponse(
          statusCode: HttpStatus.ok,
          contentLength: 5,
          headers: const {},
          stream: Stream.value(
            index == 0 ? const [1, 2] : const [1, 2, 3, 4, 5],
          ),
        );
      });
      final cache = FileRemoteAssetCache(
        directoryProvider: () async => tempDirectory,
        transport: transport,
      );
      addTearDown(cache.dispose);
      final request = RemoteAssetRequest(
        uri: Uri.parse('https://example.com/book.pdf'),
        key: const RemoteAssetKey(
          serverScope: 'https://example.com|alice',
          kind: RemoteAssetKind.document,
          identity: 'book-hash',
        ),
        fileExtension: 'pdf',
      );

      final interrupted = cache.acquire(request);
      await expectLater(interrupted.file, throwsA(isA<HttpException>()));
      await interrupted.release();

      final resumed = cache.acquire(request);
      final file = await resumed.file;
      expect(transport.requests.last.headers['Range'], 'bytes=2-');
      expect(await file.readAsBytes(), const [1, 2, 3, 4, 5]);
      await resumed.release();
    },
  );

  test(
    'a changed representation restarts an interrupted prefix with If-Range',
    () async {
      final transport = _CallbackTransport((request, index) {
        if (index == 0) {
          return RemoteAssetResponse(
            statusCode: HttpStatus.ok,
            contentLength: 5,
            headers: const {'etag': '"document-v1"'},
            stream: Stream.value(const [1, 2]),
          );
        }
        expect(request.headers['Range'], 'bytes=2-');
        expect(request.headers['If-Range'], '"document-v1"');
        return RemoteAssetResponse(
          statusCode: HttpStatus.ok,
          contentLength: 5,
          headers: const {'etag': '"document-v2"'},
          stream: Stream.value(const [9, 8, 7, 6, 5]),
        );
      });
      final cache = FileRemoteAssetCache(
        directoryProvider: () async => tempDirectory,
        transport: transport,
      );
      addTearDown(cache.dispose);
      final request = RemoteAssetRequest(
        uri: Uri.parse('https://example.com/book.pdf'),
        key: const RemoteAssetKey(
          serverScope: 'https://example.com|alice',
          kind: RemoteAssetKind.document,
          identity: 'book-varying',
        ),
        fileExtension: 'pdf',
      );

      final interrupted = cache.acquire(request);
      await expectLater(interrupted.file, throwsA(isA<HttpException>()));
      await interrupted.release();

      final resumed = cache.acquire(request);
      final file = await resumed.file;
      expect(await file.readAsBytes(), const [9, 8, 7, 6, 5]);
      await resumed.release();
    },
  );

  test(
    'a corrupted completed file is discarded and downloaded again',
    () async {
      final transport = _CallbackTransport((request, index) {
        return RemoteAssetResponse(
          statusCode: HttpStatus.ok,
          contentLength: 3,
          headers: const {},
          stream: Stream.value(index == 0 ? const [1, 2, 3] : const [4, 5, 6]),
        );
      });
      final cache = FileRemoteAssetCache(
        directoryProvider: () async => tempDirectory,
        transport: transport,
      );
      addTearDown(cache.dispose);
      const key = RemoteAssetKey(
        serverScope: 'https://example.com|alice',
        kind: RemoteAssetKind.contentImage,
        identity: 'corrupted-image',
      );
      final request = RemoteAssetRequest(
        uri: Uri.parse('https://example.com/image.png'),
        key: key,
        fileExtension: 'png',
      );

      final first = cache.acquire(request);
      final file = await first.file;
      await first.release();
      await file.writeAsBytes(const [1]);

      expect(await cache.find(key), isNull);
      final replacement = cache.acquire(request);
      expect(await (await replacement.file).readAsBytes(), const [4, 5, 6]);
      expect(transport.requests, hasLength(2));
      await replacement.release();
    },
  );

  test('a matching 416 atomically completes a fully retained prefix', () async {
    final transport = _CallbackTransport((request, index) {
      if (index == 0) {
        return RemoteAssetResponse(
          statusCode: HttpStatus.ok,
          contentLength: null,
          headers: const {},
          stream: Stream<List<int>>.multi((controller) {
            controller.add(const [1, 2, 3]);
            controller.addError(const HttpException('connection lost'));
          }),
        );
      }
      return const RemoteAssetResponse(
        statusCode: HttpStatus.requestedRangeNotSatisfiable,
        contentLength: 0,
        headers: {'content-range': 'bytes */3'},
        stream: Stream.empty(),
      );
    });
    final cache = FileRemoteAssetCache(
      directoryProvider: () async => tempDirectory,
      transport: transport,
    );
    addTearDown(cache.dispose);
    const key = RemoteAssetKey(
      serverScope: 'https://example.com|alice',
      kind: RemoteAssetKind.contentImage,
      identity: 'complete-prefix',
    );
    final request = RemoteAssetRequest(
      uri: Uri.parse('https://example.com/image.png'),
      key: key,
      fileExtension: 'png',
    );

    final interrupted = cache.acquire(request);
    await expectLater(interrupted.file, throwsA(isA<HttpException>()));
    await interrupted.release();
    final resumed = cache.acquire(request);
    final completed = await resumed.file;

    expect(await completed.readAsBytes(), const [1, 2, 3]);
    expect((await cache.find(key))?.path, completed.path);
    await resumed.release();
  });

  test(
    'HTTP cancellation interrupts a response after headers arrive',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final finishResponse = Completer<void>();
      addTearDown(() async {
        if (!finishResponse.isCompleted) finishResponse.complete();
        await server.close(force: true);
      });
      server.listen((request) async {
        request.response.contentLength = 65536;
        request.response.add(List<int>.filled(32768, 1));
        await request.response.flush();
        await finishResponse.future;
        try {
          request.response.add(List<int>.filled(32768, 2));
          await request.response.close();
        } catch (_) {
          // Expected when the client aborts the active response.
        }
      });
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final cancellation = RemoteAssetCancellation();
      final transport = HttpRemoteAssetTransport(client: client);
      final response = await transport.open(
        RemoteAssetTransportRequest(
          uri: Uri.parse('http://${server.address.host}:${server.port}/asset'),
          headers: const {},
          cancellation: cancellation,
        ),
      );
      final iterator = StreamIterator<List<int>>(response.stream);
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current, isNotEmpty);
      expect(iterator.current.first, 1);

      cancellation.cancel();

      await expectLater(
        iterator.moveNext().timeout(const Duration(seconds: 2)),
        throwsA(isA<HttpException>()),
      );
      await iterator.cancel();
    },
  );

  test('local Range and ETag service transfers one exact asset body', () async {
    const prefixLength = 32768;
    final source = List<int>.generate(65536, (index) => index % 251);
    final seenRanges = <String?>[];
    final seenIfRanges = <String?>[];
    final seenIfNoneMatches = <String?>[];
    var responseBodyBytes = 0;
    var requestCount = 0;
    final finishFirstResponse = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      requestCount++;
      seenRanges.add(request.headers.value(HttpHeaders.rangeHeader));
      seenIfRanges.add(request.headers.value(HttpHeaders.ifRangeHeader));
      seenIfNoneMatches.add(
        request.headers.value(HttpHeaders.ifNoneMatchHeader),
      );
      final response = request.response;
      response.headers.set(HttpHeaders.etagHeader, '"asset-v1"');
      try {
        if (requestCount == 1) {
          response.contentLength = source.length;
          response.add(source.take(prefixLength).toList());
          responseBodyBytes += prefixLength;
          await response.flush();
          await finishFirstResponse.future;
          await response.close();
        } else if (requestCount == 2) {
          final suffix = source.skip(prefixLength).toList();
          response.statusCode = HttpStatus.partialContent;
          response.contentLength = suffix.length;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $prefixLength-${source.length - 1}/${source.length}',
          );
          response.headers.set(HttpHeaders.cacheControlHeader, 'max-age=0');
          response.add(suffix);
          responseBodyBytes += suffix.length;
          await response.close();
        } else {
          response.statusCode = HttpStatus.notModified;
          response.headers.set(HttpHeaders.cacheControlHeader, 'max-age=3600');
          await response.close();
        }
      } catch (_) {
        // The first response intentionally closes before Content-Length.
      }
    });
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await subscription.cancel();
      await server.close(force: true);
    });
    final cache = FileRemoteAssetCache(
      directoryProvider: () async => tempDirectory,
      transport: HttpRemoteAssetTransport(client: client),
    );
    addTearDown(cache.dispose);
    final uri = Uri.parse(
      'http://${server.address.host}:${server.port}/asset?token=first',
    );
    const key = RemoteAssetKey(
      serverScope: 'http://local|alice',
      kind: RemoteAssetKind.document,
      identity: 'range-etag-fixture',
    );
    final request = RemoteAssetRequest(
      uri: uri,
      key: key,
      fileExtension: 'bin',
      maxAge: Duration.zero,
    );

    final interrupted = cache.acquire(request);
    final prefixReceived = Completer<void>();
    final progressSubscription = interrupted.progress.listen((progress) {
      if (progress.receivedBytes < prefixLength || prefixReceived.isCompleted) {
        return;
      }
      prefixReceived.complete();
      unawaited(interrupted.release());
      finishFirstResponse.complete();
    });
    await prefixReceived.future.timeout(const Duration(seconds: 2));
    await expectLater(interrupted.file, throwsA(isA<HttpException>()));
    await progressSubscription.cancel();

    final resumed = cache.acquire(request);
    final completed = await resumed.file;
    expect(await completed.readAsBytes(), source);
    await resumed.release();

    final revalidated = cache.acquire(request.copyWith(forceRevalidate: true));
    expect(await (await revalidated.file).readAsBytes(), source);
    await revalidated.release();

    expect(seenRanges, [null, 'bytes=$prefixLength-', null]);
    expect(seenIfRanges, [null, '"asset-v1"', null]);
    expect(seenIfNoneMatches, [null, null, '"asset-v1"']);
    expect(responseBodyBytes, source.length);
  });
}

class _RecordingTransport implements RemoteAssetTransport {
  _RecordingTransport(
    this.bytes, {
    this.responseDelay = Duration.zero,
    this.headers = const {},
  });

  final List<int> bytes;
  final Duration responseDelay;
  final Map<String, String> headers;
  final List<RemoteAssetTransportRequest> requests = [];

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest request) async {
    requests.add(request);
    if (responseDelay > Duration.zero) {
      await Future<void>.delayed(responseDelay);
    }
    return RemoteAssetResponse(
      statusCode: HttpStatus.ok,
      contentLength: bytes.length,
      headers: headers,
      stream: Stream.value(bytes),
    );
  }
}

class _CallbackTransport implements RemoteAssetTransport {
  _CallbackTransport(this.callback);

  final RemoteAssetResponse Function(
    RemoteAssetTransportRequest request,
    int index,
  )
  callback;
  final List<RemoteAssetTransportRequest> requests = [];

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest request) async {
    final index = requests.length;
    requests.add(request);
    return callback(request, index);
  }
}

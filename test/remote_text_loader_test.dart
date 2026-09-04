import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/remote_asset_cache.dart';
import 'package:kikoeru_flutter/src/services/remote_text_loader.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'kikoflu_remote_text_loader_test_',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test(
    'concurrent subtitle readers share raw bytes and decode at read time',
    () async {
      final sourceBytes = utf8.encode('[00:01.00]同一份字幕');
      final transport = _TextTransport(sourceBytes);
      final cache = FileRemoteAssetCache(
        directoryProvider: () async => tempDirectory,
        transport: transport,
      );
      addTearDown(cache.dispose);
      final loader = RemoteTextLoader(cache);
      const key = RemoteAssetKey(
        serverScope: 'https://example.com|alice',
        kind: RemoteAssetKind.subtitle,
        identity: 'subtitle-hash',
      );

      final automatic = loader.acquire(
        uri: Uri.parse('https://example.com/subtitle?token=first'),
        key: key,
        headers: const {},
      );
      final manual = loader.acquire(
        uri: Uri.parse('https://example.com/subtitle?token=second'),
        key: key,
        headers: const {},
      );
      final contents = await Future.wait([automatic.content, manual.content]);

      expect(transport.requests, hasLength(1));
      expect(
        contents.map((content) => content.text),
        everyElement(contains('同一份字幕')),
      );
      expect(await contents.first.file.readAsBytes(), sourceBytes);
      await automatic.release();
      await manual.release();
    },
  );

  test(
    'an interrupted subtitle retries as a whole file without Range',
    () async {
      final transport = _TextTransport(const [1, 2, 3], interruptFirst: true);
      final cache = FileRemoteAssetCache(
        directoryProvider: () async => tempDirectory,
        transport: transport,
      );
      addTearDown(cache.dispose);
      final loader = RemoteTextLoader(cache);
      const key = RemoteAssetKey(
        serverScope: 'https://example.com|alice',
        kind: RemoteAssetKind.subtitle,
        identity: 'whole-file-subtitle',
      );

      final interrupted = loader.acquire(
        uri: Uri.parse('https://example.com/subtitle'),
        key: key,
        headers: const {},
      );
      await expectLater(interrupted.content, throwsA(isA<HttpException>()));
      await interrupted.release();

      final retried = loader.acquire(
        uri: Uri.parse('https://example.com/subtitle'),
        key: key,
        headers: const {},
      );
      await retried.content;
      expect(transport.requests, hasLength(2));
      expect(transport.requests.last.headers, isNot(contains('Range')));
      await retried.release();
    },
  );

  test('a stalled subtitle request times out and releases its lease', () async {
    final transport = _StalledTextTransport();
    final cache = FileRemoteAssetCache(
      directoryProvider: () async => tempDirectory,
      transport: transport,
    );
    addTearDown(cache.dispose);
    final loader = RemoteTextLoader(
      cache,
      timeout: const Duration(milliseconds: 20),
    );
    const key = RemoteAssetKey(
      serverScope: 'https://example.com|alice',
      kind: RemoteAssetKind.subtitle,
      identity: 'stalled-subtitle',
    );

    final lease = loader.acquire(
      uri: Uri.parse('https://example.com/subtitle'),
      key: key,
      headers: const {},
    );

    await expectLater(lease.content, throwsA(isA<TimeoutException>()));
    expect(transport.cancelled, isTrue);
    await lease.release();
  });
}

class _TextTransport implements RemoteAssetTransport {
  _TextTransport(this.bytes, {this.interruptFirst = false});

  final List<int> bytes;
  final bool interruptFirst;
  final List<RemoteAssetTransportRequest> requests = [];

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest request) async {
    requests.add(request);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final shouldInterrupt = interruptFirst && requests.length == 1;
    return RemoteAssetResponse(
      statusCode: HttpStatus.ok,
      contentLength: bytes.length,
      headers: const {},
      stream: Stream.value(shouldInterrupt ? bytes.take(1).toList() : bytes),
    );
  }
}

class _StalledTextTransport implements RemoteAssetTransport {
  final StreamController<List<int>> _controller = StreamController<List<int>>();
  bool cancelled = false;

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest request) async {
    unawaited(
      request.cancellation.whenCancelled.then((_) async {
        cancelled = true;
        await _controller.close();
      }),
    );
    return RemoteAssetResponse(
      statusCode: HttpStatus.ok,
      contentLength: 1,
      headers: const {},
      stream: _controller.stream,
    );
  }
}

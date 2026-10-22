import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/remote_asset_cache.dart';
import 'package:kikoeru_flutter/src/videos/missav_media_server.dart';

void main() {
  late HttpClient client;
  late _FakeTransport transport;
  late MissavMediaServer server;

  setUp(() async {
    client = HttpClient();
    transport = _FakeTransport();
    server = await MissavMediaServer.start(transport);
  });

  tearDown(() async {
    await server.close();
    client.close(force: true);
  });

  test(
    'rewrites master, media, key, and map URIs to registered local URLs',
    () async {
      final masterUri = Uri.parse(
        'https://surrit.com/open/playlist.m3u8?signature=seed',
      );
      final masterBody = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1800000
media/index.m3u8?quality=high
''';
      transport.whenOpened(masterUri, () => _response(masterBody));

      final localMaster = server.register(masterUri);
      expect(localMaster.path, endsWith('.m3u8'));
      expect(localMaster.query, isEmpty);
      final masterResponse = await _get(localMaster);
      expect(masterResponse.statusCode, HttpStatus.ok);
      final rewrittenMaster = await utf8.decoder.bind(masterResponse).join();
      final localMediaText = rewrittenMaster
          .split('\n')
          .firstWhere((line) => line.startsWith('http://'));
      final localMedia = Uri.parse(localMediaText);
      expect(localMedia.host, '127.0.0.1');
      expect(localMedia.path, endsWith('.m3u8'));
      expect(localMedia.query, isEmpty);

      final mediaUri = Uri.parse(
        'https://surrit.com/open/media/index.m3u8?quality=high',
      );
      transport.whenOpened(
        mediaUri,
        () => _response('''#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="../keys/key.bin?key=1"
#EXT-X-MAP:URI="init.mp4"
#EXTINF:4.0,
segment.ts?part=1
'''),
      );

      final mediaResponse = await _get(localMedia);
      expect(mediaResponse.statusCode, HttpStatus.ok);
      expect(
        mediaResponse.headers.contentType?.mimeType,
        'application/vnd.apple.mpegurl',
      );
      final rewrittenMedia = await utf8.decoder.bind(mediaResponse).join();
      final localKey = _attributeUri(rewrittenMedia, 'KEY');
      final localMap = _attributeUri(rewrittenMedia, 'MAP');
      final localSegment = Uri.parse(
        rewrittenMedia
            .split('\n')
            .firstWhere((line) => line.startsWith('http://')),
      );

      expect(localKey.host, '127.0.0.1');
      expect(localKey.path, endsWith('.bin'));
      expect(localMap.host, '127.0.0.1');
      expect(localMap.path, endsWith('.mp4'));
      expect(localSegment.host, '127.0.0.1');
      expect(localSegment.path, endsWith('.ts'));
      expect(transport.requests.map((request) => request.uri), [
        masterUri,
        mediaUri,
      ]);
    },
  );

  test('streams binary ranges without forwarding local cookies or auth', () async {
    final source = Uri.parse('https://surrit.com/video/clip.mp4?token=abc');
    transport.whenOpened(
      source,
      () => _responseBytes(
        [4, 5, 6],
        statusCode: HttpStatus.partialContent,
        headers: const {
          'content-type': 'video/mp4',
          'content-range': 'bytes 4-6/10',
          'accept-ranges': 'bytes',
          'content-encoding': 'gzip',
          'connection': 'keep-alive',
          'set-cookie': 'source=secret',
        },
      ),
    );

    final local = server.register(source);
    final request = await client.getUrl(local);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=4-6');
    request.headers.set(HttpHeaders.cookieHeader, 'local=must-not-forward');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer local');
    final response = await request.close();

    expect(response.statusCode, HttpStatus.partialContent);
    expect(response.headers.value('content-range'), 'bytes 4-6/10');
    expect(response.headers.value('content-encoding'), isNull);
    expect(response.headers.value('connection'), isNull);
    expect(response.headers.value('set-cookie'), isNull);
    expect(
      await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
      [4, 5, 6],
    );
    expect(transport.requests, hasLength(1));
    expect(transport.requests.single.headers['range'], 'bytes=4-6');
    expect(transport.requests.single.headers, isNot(contains('cookie')));
    expect(transport.requests.single.headers, isNot(contains('authorization')));
  });

  test('serves HEAD metadata without forwarding the response body', () async {
    final source = Uri.parse('https://surrit.com/video/clip.mp4');
    transport.whenOpened(
      source,
      () => _responseBytes(
        [1, 2, 3],
        headers: const {'content-type': 'video/mp4'},
      ),
    );

    final request = await client.openUrl('HEAD', server.register(source));
    final response = await request.close();

    expect(response.statusCode, HttpStatus.ok);
    expect(response.contentLength, 3);
    expect(
      await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
      isEmpty,
    );
    expect(transport.requests, hasLength(1));
  });

  test('cancels the remote body when the local client disconnects', () async {
    final source = Uri.parse('https://surrit.com/video/clip.mp4');
    final bodyListening = Completer<void>();
    final body = StreamController<List<int>>(
      onListen: bodyListening.complete,
    );
    final remoteStarted = Completer<RemoteAssetCancellation>();
    transport.onOpen = (request) async {
      remoteStarted.complete(request.cancellation);
      return RemoteAssetResponse(
        statusCode: HttpStatus.ok,
        headers: const {'content-type': 'video/mp4'},
        stream: body.stream,
      );
    };

    final request = await client.getUrl(server.register(source));
    final response = await request.close();
    final cancellation = await remoteStarted.future;
    await bodyListening.future.timeout(const Duration(seconds: 2));
    final subscription = response.listen((_) {});
    await subscription.cancel();
    body.add([1, 2, 3]);

    await cancellation.whenCancelled.timeout(const Duration(seconds: 2));
    expect(cancellation.isCancelled, isTrue);
    await body.close();
  });

  test('rejects unregistered paths, query strings, and non-GET methods', () async {
    final registered = server.register(
      Uri.parse('https://surrit.com/video/clip.mp4'),
    );

    final unknown = await _get(
      registered.replace(path: '/media/not-a-token/clip.mp4'),
    );
    expect(unknown.statusCode, HttpStatus.notFound);
    await unknown.drain<void>();

    final withQuery = await _get(registered.replace(query: 'url=https://x'));
    expect(withQuery.statusCode, HttpStatus.notFound);
    await withQuery.drain<void>();

    final request = await client.postUrl(registered);
    final post = await request.close();
    expect(post.statusCode, HttpStatus.methodNotAllowed);
    expect(post.headers.value('allow'), 'GET, HEAD');
    await post.drain<void>();
    expect(transport.requests, isEmpty);
  });

  test('rejects cross-origin HLS dependencies before fetching them', () async {
    final source = Uri.parse('https://surrit.com/open/playlist.m3u8');
    transport.whenOpened(source, () => _response('''#EXTM3U
https://fourhoi.com/segment.ts
'''));

    final response = await _get(server.register(source));
    expect(response.statusCode, HttpStatus.badGateway);
    await response.drain<void>();
    expect(transport.requests.map((request) => request.uri), [source]);
  });

  test('cancels an active remote request when the server closes', () async {
    final source = Uri.parse('https://surrit.com/open/playlist.m3u8');
    final started = Completer<RemoteAssetCancellation>();
    transport.onOpen = (request) async {
      started.complete(request.cancellation);
      await request.cancellation.whenCancelled;
      throw const HttpException('cancelled');
    };

    final local = server.register(source);
    final pendingResponse = _get(local).then<Object>(
      (response) => response,
      onError: (Object error) => error,
    );
    final cancellation = await started.future.timeout(
      const Duration(seconds: 2),
    );
    await server.close();

    expect(cancellation.isCancelled, isTrue);
    await pendingResponse;
  });

  test('requires public HTTPS seed URIs', () {
    expect(
      () => server.register(Uri.parse('http://surrit.com/clip.mp4')),
      throwsArgumentError,
    );
    expect(
      () => server.register(Uri.parse('https://127.0.0.1/clip.mp4')),
      throwsArgumentError,
    );
  });

  Future<HttpClientResponse> _get(Uri uri) async {
    final request = await client.getUrl(uri);
    return request.close();
  }
}

Uri _attributeUri(String manifest, String tag) {
  final line = manifest
      .split('\n')
      .firstWhere((value) => value.startsWith('#EXT-X-$tag:'));
  final value = RegExp(r'URI="([^"]+)"').firstMatch(line)!.group(1)!;
  return Uri.parse(value);
}

RemoteAssetResponse _response(
  String value, {
  int statusCode = HttpStatus.ok,
  Map<String, String> headers = const {
    'content-type': 'application/vnd.apple.mpegurl',
  },
}) =>
    _responseBytes(utf8.encode(value), statusCode: statusCode, headers: headers);

RemoteAssetResponse _responseBytes(
  List<int> bytes, {
  int statusCode = HttpStatus.ok,
  Map<String, String> headers = const {},
}) =>
    RemoteAssetResponse(
      statusCode: statusCode,
      contentLength: bytes.length,
      headers: headers,
      stream: Stream<List<int>>.value(bytes),
    );

class _FakeTransport implements RemoteAssetTransport {
  final Map<String, RemoteAssetResponse Function()> _responses = {};
  final List<RemoteAssetTransportRequest> requests = [];
  Future<RemoteAssetResponse> Function(RemoteAssetTransportRequest)? onOpen;

  void whenOpened(Uri uri, RemoteAssetResponse Function() response) {
    _responses[uri.toString()] = response;
  }

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest request) async {
    requests.add(request);
    final onOpen = this.onOpen;
    if (onOpen != null) return onOpen(request);
    final response = _responses[request.uri.toString()];
    if (response != null) return response();
    return _responseBytes(
      const [],
      statusCode: HttpStatus.notFound,
      headers: const {'content-type': 'application/octet-stream'},
    );
  }
}

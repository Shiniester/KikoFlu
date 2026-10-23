import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../services/remote_asset_cache.dart';

class MissavMediaServer {
  MissavMediaServer._(this._server, this._transport) {
    _requestSubscription = _server.listen(_acceptRequest);
  }

  static const _playlistLimit = 2 * 1024 * 1024;
  static const _mediaPath = 'media';
  static const _requestHeaders = {
    'accept',
    'accept-language',
    'if-range',
    'origin',
    'range',
    'referer',
    'user-agent',
  };
  static const _hopByHopHeaders = {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };
  static const _manifestHeaders = {
    'accept-ranges',
    'content-encoding',
    'content-length',
    'content-md5',
    'content-range',
    'digest',
    'etag',
  };

  final HttpServer _server;
  final RemoteAssetTransport _transport;
  final Map<String, _RegisteredMedia> _registrations = {};
  final Map<String, String> _tokenBySource = {};
  final Set<String> _seedOrigins = {};
  final Set<RemoteAssetCancellation> _activeRequests = {};
  final Set<Future<void>> _handlers = {};
  final Random _random = Random.secure();
  late final StreamSubscription<HttpRequest> _requestSubscription;
  bool _closed = false;
  Future<void>? _closeFuture;

  static Future<MissavMediaServer> start(RemoteAssetTransport transport) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return MissavMediaServer._(server, transport);
  }

  Uri register(Uri source) {
    if (_closed) throw StateError('The media server is closed.');
    final normalized = _requirePublicHttps(source);
    _seedOrigins.add(_origin(normalized));
    return _register(normalized);
  }

  Future<void> close() => _closeFuture ??= _close();

  void _acceptRequest(HttpRequest request) {
    final handler = _handleRequest(request);
    _handlers.add(handler);
    unawaited(
      handler.then<void>(
        (_) => _handlers.remove(handler),
        onError: (Object _, StackTrace __) => _handlers.remove(handler),
      ),
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final cancellation = RemoteAssetCancellation();
    _activeRequests.add(cancellation);
    final response = request.response;
    unawaited(
      response.done.then<void>(
        (_) => cancellation.cancel(),
        onError: (Object _, StackTrace __) => cancellation.cancel(),
      ),
    );

    var responseCommitted = false;
    try {
      if (_closed) throw const _MediaRequestCancelled();
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set('allow', 'GET, HEAD');
        await response.close();
        return;
      }

      final registration = _findRegistration(request.uri);
      if (registration == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final isHead = request.method == 'HEAD';
      final isManifest = _isManifest(registration.source);
      var remoteResponse = await _openRemote(
        registration.source,
        _copyRequestHeaders(request, includeRange: !isManifest),
        cancellation,
      );
      _ensureActive(cancellation);
      if (remoteResponse.statusCode == HttpStatus.partialContent &&
          remoteResponse.header('content-range') == null &&
          request.headers.value(HttpHeaders.rangeHeader) != null) {
        // CORS can hide Content-Range; restart this resource instead of
        // appending bytes whose offset the browser cannot verify.
        await remoteResponse.stream.listen(null).cancel();
        remoteResponse = await _openRemote(
          registration.source,
          _copyRequestHeaders(request, includeRange: false),
          cancellation,
        );
        _ensureActive(cancellation);
      }

      if (_isManifestResponse(registration.source, remoteResponse) &&
          remoteResponse.statusCode == HttpStatus.ok) {
        final manifestUri = _requirePublicHttps(
          remoteResponse.finalUri ?? registration.source,
        );
        _seedOrigins.add(_origin(manifestUri));
        final bytes = await _rewriteManifest(
          manifestUri,
          remoteResponse.stream,
          cancellation,
        );
        _ensureActive(cancellation);
        _copyResponseHeaders(response, remoteResponse, rewrittenManifest: true);
        response.statusCode = remoteResponse.statusCode;
        response.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/vnd.apple.mpegurl',
        );
        response.contentLength = bytes.length;
        responseCommitted = true;
        if (isHead) {
          await response.close();
        } else {
          response.add(bytes);
          await response.close();
        }
        return;
      }

      _copyResponseHeaders(response, remoteResponse);
      response.statusCode = remoteResponse.statusCode;
      final length = _responseContentLength(remoteResponse);
      if (length != null) response.contentLength = length;
      responseCommitted = true;
      if (isHead) {
        await _cancelRemoteBody(remoteResponse.stream, cancellation);
        await response.close();
        return;
      }

      try {
        response.bufferOutput = false;
        await response.flush();
        await response.addStream(
          _cancellableStream(remoteResponse.stream, cancellation),
        );
      } on Object {
        cancellation.cancel();
        rethrow;
      }
      await response.close();
    } on _MediaRequestCancelled {
      await _closeResponse(response);
    } on Object {
      if (!cancellation.isCancelled && !_closed && !responseCommitted) {
        response.statusCode = HttpStatus.badGateway;
      }
      await _closeResponse(response);
    } finally {
      cancellation.cancel();
      _activeRequests.remove(cancellation);
    }
  }

  Future<RemoteAssetResponse> _openRemote(
    Uri source,
    Map<String, String> headers,
    RemoteAssetCancellation cancellation,
  ) {
    return Future.any<RemoteAssetResponse>([
      _transport.open(
        RemoteAssetTransportRequest(
          uri: source,
          headers: headers,
          cancellation: cancellation,
        ),
      ),
      cancellation.whenCancelled.then<RemoteAssetResponse>(
        (_) => throw const _MediaRequestCancelled(),
      ),
    ]);
  }

  Map<String, String> _copyRequestHeaders(
    HttpRequest request, {
    required bool includeRange,
  }) {
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      final normalized = name.toLowerCase();
      if (!_requestHeaders.contains(normalized) ||
          (!includeRange &&
              (normalized == 'range' || normalized == 'if-range'))) {
        return;
      }
      if (values.isNotEmpty) headers[normalized] = values.join(',');
    });
    return headers;
  }

  void _copyResponseHeaders(
    HttpResponse target,
    RemoteAssetResponse source, {
    bool rewrittenManifest = false,
  }) {
    final connectionHeaders = (source.header('connection') ?? '')
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toSet();
    for (final entry in source.headers.entries) {
      final name = entry.key.toLowerCase();
      if (_hopByHopHeaders.contains(name) ||
          connectionHeaders.contains(name) ||
          name == 'set-cookie' ||
          name == 'set-cookie2' ||
          name == 'content-length' ||
          name == 'content-encoding' ||
          (rewrittenManifest && _manifestHeaders.contains(name))) {
        continue;
      }
      target.headers.set(name, entry.value);
    }
  }

  Future<Uint8List> _rewriteManifest(
    Uri manifestUri,
    Stream<List<int>> stream,
    RemoteAssetCancellation cancellation,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in _cancellableStream(stream, cancellation)) {
      _ensureActive(cancellation);
      if (builder.length + chunk.length > _playlistLimit) {
        throw const FormatException('The HLS playlist is too large.');
      }
      builder.add(chunk);
    }

    final sourceBytes = builder.takeBytes();
    final sourceText = utf8.decode(sourceBytes, allowMalformed: false);
    final lines = const LineSplitter().convert(sourceText);
    if (!lines.any((line) => line.trim() == '#EXTM3U')) {
      throw const FormatException('The response is not an HLS playlist.');
    }

    final output = StringBuffer();
    var outputBytes = 0;
    void append(String value) {
      outputBytes += utf8.encode(value).length;
      if (outputBytes > _playlistLimit) {
        throw const FormatException('The rewritten HLS playlist is too large.');
      }
      output.write(value);
    }

    for (var index = 0; index < lines.length; index++) {
      if (index > 0) append('\n');
      final line = lines[index];
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        append(line);
        continue;
      }
      if (trimmed.startsWith('#')) {
        append(_rewriteUriAttributes(line, manifestUri));
      } else {
        append(_registerDependency(manifestUri, trimmed).toString());
      }
    }
    if (sourceText.endsWith('\n') || sourceText.endsWith('\r')) append('\n');
    return Uint8List.fromList(utf8.encode(output.toString()));
  }

  String _rewriteUriAttributes(String line, Uri manifestUri) {
    final uriAttribute = RegExp(
      r'(\bURI\s*=\s*")([^"]*)(")',
      caseSensitive: false,
    );
    return line.replaceAllMapped(uriAttribute, (match) {
      final value = match.group(2)!;
      final local = _registerDependency(manifestUri, value);
      return '${match.group(1)}$local${match.group(3)}';
    });
  }

  Uri _registerDependency(Uri base, String reference) =>
      _register(_resolveDependency(base, reference));

  Uri _resolveDependency(Uri base, String reference) {
    final resolved = _requirePublicHttps(base.resolve(reference));
    if (!_seedOrigins.contains(_origin(resolved))) {
      throw const FormatException(
        'The HLS playlist references another origin.',
      );
    }
    return resolved;
  }

  Uri _register(Uri source) {
    final sourceKey = source.toString();
    final existing = _tokenBySource[sourceKey];
    if (existing != null) return _localUri(source, token: existing);

    final token = _newToken();
    final pathSegments = source.pathSegments;
    final suffix = pathSegments.isEmpty || pathSegments.last.isEmpty
        ? 'media'
        : pathSegments.last;
    _registrations[token] = _RegisteredMedia(source, suffix);
    _tokenBySource[sourceKey] = token;
    return _localUri(source, token: token);
  }

  Uri _localUri(Uri source, {String? token}) {
    token ??= _tokenBySource[source.toString()];
    if (token == null) {
      throw StateError('The media URI has not been registered.');
    }
    final suffix = _registrations[token]!.suffix;
    return Uri(
      scheme: 'http',
      host: _server.address.address,
      port: _server.port,
      pathSegments: [_mediaPath, token, suffix],
    );
  }

  _RegisteredMedia? _findRegistration(Uri localUri) {
    if (localUri.hasQuery || localUri.hasFragment) return null;
    final segments = localUri.pathSegments;
    if (segments.length != 3 || segments.first != _mediaPath) return null;
    final registration = _registrations[segments[1]];
    if (registration == null || segments[2] != registration.suffix) {
      return null;
    }
    return registration;
  }

  String _newToken() {
    while (true) {
      final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
      final token = base64Url.encode(bytes).replaceAll('=', '');
      if (!_registrations.containsKey(token)) return token;
    }
  }

  Future<void> _cancelRemoteBody(
    Stream<List<int>> stream,
    RemoteAssetCancellation cancellation,
  ) async {
    cancellation.cancel();
    try {
      await _cancellableStream(stream, cancellation).drain<void>();
    } on Object {
      // Cancelling the stream is the purpose of this drain.
    }
  }

  Stream<List<int>> _cancellableStream(
    Stream<List<int>> source,
    RemoteAssetCancellation cancellation,
  ) async* {
    final iterator = StreamIterator<List<int>>(source);
    final cancelled = cancellation.whenCancelled.then<bool>((_) => false);
    var completed = false;
    try {
      while (true) {
        final hasNext = await Future.any<bool>([
          iterator.moveNext(),
          cancelled,
        ]);
        if (!hasNext) {
          completed = true;
          return;
        }
        yield iterator.current;
      }
    } finally {
      if (!completed) cancellation.cancel();
      await iterator.cancel();
    }
  }

  void _ensureActive(RemoteAssetCancellation cancellation) {
    if (_closed || cancellation.isCancelled) {
      throw const _MediaRequestCancelled();
    }
  }

  Future<void> _close() async {
    _closed = true;
    for (final cancellation in _activeRequests.toList()) {
      cancellation.cancel();
    }
    await _server.close(force: true);
    await _requestSubscription.cancel();
    while (_handlers.isNotEmpty) {
      await Future.wait(_handlers.toList(), eagerError: false);
    }
    _registrations.clear();
    _tokenBySource.clear();
    _seedOrigins.clear();
  }

  Future<void> _closeResponse(HttpResponse response) async {
    try {
      await response.close();
    } on Object {
      // The peer may have closed the loopback connection already.
    }
  }

  bool _isManifestResponse(Uri source, RemoteAssetResponse response) {
    if (_isManifest(source)) return true;
    final contentType = (response.header('content-type') ?? '').toLowerCase();
    return contentType.contains('mpegurl') ||
        contentType.contains('vnd.apple.mpegurl');
  }

  bool _isManifest(Uri uri) => uri.path.toLowerCase().endsWith('.m3u8');

  int? _responseContentLength(RemoteAssetResponse response) {
    final contentEncoding = response.header('content-encoding');
    if (contentEncoding != null &&
        contentEncoding.toLowerCase().trim() != 'identity') {
      return null;
    }
    final length = response.contentLength;
    if (length != null) return length;
    return int.tryParse(response.header('content-length') ?? '');
  }

  static Uri _requirePublicHttps(Uri uri) {
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (uri.scheme.toLowerCase() != 'https' ||
        host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.port == 0 ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.endsWith('.test') ||
        host.endsWith('.invalid') ||
        host.endsWith('.example') ||
        host == 'example.com' ||
        host.endsWith('.example.com')) {
      throw ArgumentError.value(uri, 'source', 'Expected a public HTTPS URI.');
    }

    final address = InternetAddress.tryParse(host);
    if (address != null && !_isPublicAddress(address)) {
      throw ArgumentError.value(uri, 'source', 'Expected a public HTTPS URI.');
    }
    if (address == null && !host.contains('.')) {
      throw ArgumentError.value(uri, 'source', 'Expected a public HTTPS URI.');
    }
    return uri.removeFragment();
  }

  static bool _isPublicAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = bytes[0];
      final b = bytes[1];
      final c = bytes[2];
      if (a == 0 ||
          a == 10 ||
          a == 127 ||
          a >= 224 ||
          (a == 100 && b >= 64 && b <= 127) ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 192 && b == 0 && c == 0) ||
          (a == 192 && b == 0 && c == 2) ||
          (a == 192 && b == 88 && c == 99) ||
          (a == 198 && (b == 18 || b == 19)) ||
          (a == 198 && b == 51 && c == 100) ||
          (a == 203 && b == 0 && c == 113)) {
        return false;
      }
      return true;
    }

    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }
    if ((bytes[0] & 0xfe) == 0xfc ||
        (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)) {
      return false;
    }
    final isMappedIpv4 =
        bytes.sublist(0, 10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (isMappedIpv4) {
      return _isPublicAddress(
        InternetAddress.fromRawAddress(bytes.sublist(12)),
      );
    }
    if ((bytes[0] & 0xe0) != 0x20) return false;
    if (bytes[0] == 0x20 &&
        bytes[1] == 0x01 &&
        bytes[2] == 0x0d &&
        bytes[3] == 0xb8) {
      return false;
    }
    return true;
  }

  static String _origin(Uri uri) => uri.origin.toLowerCase();
}

class _RegisteredMedia {
  const _RegisteredMedia(this.source, this.suffix);

  final Uri source;
  final String suffix;
}

class _MediaRequestCancelled implements Exception {
  const _MediaRequestCancelled();
}

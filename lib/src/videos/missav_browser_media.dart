import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../services/remote_asset_cache.dart';

/// Streams public HTTPS media through the isolated MissAV browser session.
class MissavBrowserMediaTransport implements RemoteAssetTransport {
  MissavBrowserMediaTransport({
    required this.runJavaScript,
    required this.currentUrl,
    required this.disposeBrowser,
  }) : _nonce = base64UrlEncode(
         List<int>.generate(24, (_) => Random.secure().nextInt(256)),
       );

  final Future<void> Function(String script) runJavaScript;
  final Future<String?> Function() currentUrl;
  final Future<void> Function() disposeBrowser;
  final String _nonce;
  final _requests = <int, _MediaRequest>{};
  var _nextId = 0;
  var _closed = false;
  final _closedCompletion = Completer<void>();

  static const channelName = 'KikoMissavMedia';
  static const _origin = 'https://missav.ai';
  static const _timeout = Duration(seconds: 30);
  static const _chunkSize = 64 * 1024;

  Future<void> get whenClosed => _closedCompletion.future;

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest input) async {
    if (_closed) throw StateError('MissAV media browser is closed.');
    if (!_isPublicHttps(input.uri)) {
      throw HttpException('Unsupported media URL: ${input.uri}');
    }

    final id = ++_nextId;
    late final _MediaRequest request;
    final streamController = StreamController<List<int>>(
      onListen: () => _deliverPending(request),
      onPause: () => request.consumerPaused = true,
      onResume: () {
        request.consumerPaused = false;
        _ackPending(request);
        _deliverPending(request);
      },
      onCancel: () {
        request.consumerCancelled = true;
        _cancelRequest(
          request,
          const HttpException('Media stream was cancelled.'),
        );
      },
    );
    request = _MediaRequest(id, input, streamController);
    _requests[id] = request;
    unawaited(
      input.cancellation.whenCancelled.then((_) {
        _cancelRequest(
          request,
          const HttpException('Media request was cancelled.'),
        );
      }),
    );

    try {
      final sourceUrl = await _awaitRequest(
        request,
        currentUrl(),
        timeout: _timeout,
      );
      if (!_isSourcePage(sourceUrl)) {
        throw const HttpException('MissAV media browser is on another page.');
      }
      _ensureRequestActive(request);
      request.scriptStarted = true;
      await _awaitRequest(
        request,
        runJavaScript(_fetchScript(request)),
        timeout: _timeout,
      );
      _ensureRequestActive(request);
      request.waitingForHeaders = true;
      final response = await _awaitRequest(
        request,
        request.headers.future,
        timeout: _timeout,
      );
      _ensureRequestActive(request);
      request.responseReturned = true;
      return response;
    } catch (error, stackTrace) {
      _terminate(request, error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void receiveMessage(Object? message, {String? origin}) {
    if (_closed || (origin != null && origin != _origin)) return;
    try {
      final data = message is String ? jsonDecode(message) : message;
      if (data is! Map ||
          data['nonce'] != _nonce ||
          data['origin'] != _origin ||
          data['id'] is! int ||
          data['type'] is! String) {
        return;
      }
      final request = _requests[data['id'] as int];
      if (request == null || request.failed || request.finished) return;

      switch (data['type']) {
        case 'headers':
          _receiveHeaders(request, data);
          break;
        case 'chunk':
          _receiveChunk(request, data);
          break;
        case 'end':
          _finishRequest(request);
          break;
        case 'error':
          _terminate(
            request,
            HttpException(
              data['message'] is String
                  ? data['message'] as String
                  : 'Browser media request failed.',
              uri: request.input.uri,
            ),
            StackTrace.current,
          );
          break;
      }
    } on FormatException {
      // Ignore unrelated browser channel messages.
    } on TypeError {
      // Ignore malformed browser messages.
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final request in _requests.values.toList()) {
      _terminate(
        request,
        StateError('MissAV media browser was closed.'),
        StackTrace.current,
        abortBrowser: false,
      );
    }
    final cleanup = () async {
      try {
        await runJavaScript('''
for (const request of window.__kikoMissavMediaRequests?.values() ?? []) {
  request.controller.abort();
  for (const resolve of request.acks.values()) resolve();
}
window.__kikoMissavMediaClosed = true;
window.__kikoMissavMediaRequests?.clear();
''').timeout(const Duration(seconds: 2));
      } catch (_) {
        // Closing the page may already have stopped its scripts.
      }
      await disposeBrowser();
    }();
    _closedCompletion.complete(cleanup);
    _closedCompletion.future.ignore();
  }

  void _receiveHeaders(_MediaRequest request, Map data) {
    if (request.headersReceived ||
        data['status'] is! int ||
        data['url'] is! String) {
      _terminate(
        request,
        const HttpException('Invalid browser media response headers.'),
        StackTrace.current,
      );
      return;
    }
    final finalUri = Uri.tryParse(data['url'] as String);
    final status = data['status'] as int;
    if (status < 100 ||
        status > 599 ||
        finalUri == null ||
        !_isPublicHttps(finalUri)) {
      _terminate(
        request,
        HttpException('Unsupported media response URL: ${data['url']}'),
        StackTrace.current,
      );
      return;
    }
    final rawHeaders = data['headers'];
    if (rawHeaders is! Map) {
      _terminate(
        request,
        const HttpException('Invalid browser media response headers.'),
        StackTrace.current,
      );
      return;
    }
    final headers = <String, String>{};
    for (final entry in rawHeaders.entries) {
      final name = '${entry.key}'.toLowerCase();
      final value = '${entry.value}';
      if (RegExp(r"^[!#$%&'*+.^_`|~0-9a-z-]+$").hasMatch(name) &&
          !value.contains('\r') &&
          !value.contains('\n')) {
        headers[name] = value;
      }
    }
    final length = int.tryParse(headers['content-length'] ?? '');
    request.headersReceived = true;
    _armIdleTimer(request);
    request.headers.complete(
      RemoteAssetResponse(
        statusCode: status,
        finalUri: finalUri,
        contentLength: length != null && length >= 0 ? length : null,
        headers: headers,
        stream: request.streamController.stream,
      ),
    );
  }

  void _receiveChunk(_MediaRequest request, Map data) {
    final index = data['index'];
    final encoded = data['data'];
    if (!request.headersReceived ||
        index is! int ||
        index != request.nextChunkIndex ||
        encoded is! String ||
        request.pendingChunk != null ||
        request.pendingAck != null) {
      _terminate(
        request,
        const HttpException('Invalid browser media chunk.'),
        StackTrace.current,
      );
      return;
    }
    try {
      final bytes = base64Decode(encoded);
      if (bytes.isEmpty || bytes.length > _chunkSize) {
        throw const FormatException('Invalid media chunk size.');
      }
      request.nextChunkIndex++;
      request.pendingChunk = _PendingMediaChunk(index, bytes);
      request.idleTimer?.cancel();
      _deliverPending(request);
    } on FormatException catch (error) {
      _terminate(request, error, StackTrace.current);
    }
  }

  void _deliverPending(_MediaRequest request) {
    final chunk = request.pendingChunk;
    final controller = request.streamController;
    if (request.failed ||
        request.finished ||
        chunk == null ||
        !controller.hasListener ||
        request.consumerPaused ||
        controller.isPaused) {
      return;
    }
    request.pendingChunk = null;
    request.pendingAck = chunk.index;
    controller.add(chunk.bytes);
    Timer.run(() => _ackPending(request));
  }

  void _ackPending(_MediaRequest request) {
    final index = request.pendingAck;
    final controller = request.streamController;
    if (request.failed ||
        request.finished ||
        index == null ||
        !controller.hasListener ||
        request.consumerPaused ||
        controller.isPaused) {
      return;
    }
    request.pendingAck = null;
    _armIdleTimer(request);
    final script =
        '''
window.__kikoMissavMediaRequests?.get(${request.id})?.acks.get($index)?.();
''';
    unawaited(
      runJavaScript(script).catchError((Object error, StackTrace trace) {
        _terminate(request, error, trace);
      }),
    );
  }

  void _finishRequest(_MediaRequest request) {
    if (!request.headersReceived) {
      _terminate(
        request,
        const HttpException('Media stream ended before response headers.'),
        StackTrace.current,
      );
      return;
    }
    if (request.pendingChunk != null || request.pendingAck != null) {
      _terminate(
        request,
        const HttpException(
          'Media stream ended before its chunk was accepted.',
        ),
        StackTrace.current,
      );
      return;
    }
    request.finished = true;
    request.idleTimer?.cancel();
    request.streamController.close();
    _requests.remove(request.id);
  }

  void _cancelRequest(_MediaRequest request, Object error) {
    if (request.failed || request.finished) return;
    _terminate(request, error, StackTrace.current);
  }

  void _terminate(
    _MediaRequest request,
    Object error,
    StackTrace stackTrace, {
    bool abortBrowser = true,
  }) {
    if (request.failed || request.finished) return;
    request.failed = true;
    request.failure = error;
    request.idleTimer?.cancel();
    _requests.remove(request.id);
    if (!request.headers.isCompleted && request.waitingForHeaders) {
      request.headers.completeError(error, stackTrace);
    }
    if (request.responseReturned && !request.consumerCancelled) {
      request.streamController.addError(error, stackTrace);
    }
    request.streamController.close();
    request.terminated.complete(error);
    if (abortBrowser && !_closed) unawaited(_abortRequest(request));
  }

  void _armIdleTimer(_MediaRequest request) {
    request.idleTimer?.cancel();
    if (request.failed || request.finished || request.pendingAck != null) {
      return;
    }
    request.idleTimer = Timer(_timeout, () {
      _cancelRequest(
        request,
        TimeoutException('Browser media stream was idle for 30 seconds.'),
      );
    });
  }

  Future<void> _abortRequest(_MediaRequest request) async {
    if (_closed || !request.scriptStarted) return;
    final id = request.id;
    try {
      await runJavaScript('''
(() => {
  const requests = window.__kikoMissavMediaRequests ||= new Map();
  const request = requests.get($id);
  if (request) {
    request.controller.abort();
    for (const resolve of request.acks.values()) resolve();
    request.acks.clear();
  } else {
    const cancelled = window.__kikoMissavMediaCancelled ||= new Set();
    cancelled.add($id);
  }
})();
''');
    } catch (_) {
      // The media page may already be closed.
    }
  }

  Future<T> _awaitRequest<T>(
    _MediaRequest request,
    Future<T> operation, {
    required Duration timeout,
  }) {
    _ensureRequestActive(request);
    return Future.any<T>([
      operation,
      request.terminated.future.then<T>((error) {
        Error.throwWithStackTrace(error, StackTrace.current);
      }),
    ]).timeout(timeout);
  }

  void _ensureRequestActive(_MediaRequest request) {
    if (_closed) throw StateError('MissAV media browser is closed.');
    if (request.failed) {
      Error.throwWithStackTrace(request.failure!, StackTrace.current);
    }
    if (request.input.cancellation.isCancelled) {
      throw const HttpException('Media request was cancelled.');
    }
  }

  String _fetchScript(_MediaRequest request) {
    final headers = <String, String>{};
    for (final entry in request.input.headers.entries) {
      final name = entry.key.toLowerCase();
      if (name != 'range' && name != 'if-range') {
        continue;
      }
      if (entry.value.contains('\r') || entry.value.contains('\n')) {
        throw HttpException('Invalid media request header: ${entry.key}');
      }
      headers[name] = entry.value;
    }
    final descriptor = jsonEncode({
      'id': request.id,
      'nonce': _nonce,
      'url': request.input.uri.toString(),
      'headers': headers,
    });
    return '''
(() => {
const request = $descriptor;
if (window.__kikoMissavMediaClosed) return;
if (window.__kikoMissavMediaCancelled?.delete(request.id)) return;
const requests = window.__kikoMissavMediaRequests ||= new Map();
const entry = {controller:new AbortController(), acks:new Map()};
requests.set(request.id, entry);
const send = data => {
  const message = {...data, id:request.id, nonce:request.nonce, origin:location.origin};
  if (window.desktopWebview) {
    window.desktopWebview.postMessage('$channelName', message);
  } else {
    window.$channelName.postMessage(JSON.stringify(message));
  }
};
(async () => {
  try {
    if (location.origin !== '$_origin') throw new Error('Wrong browser origin');
    const response = await fetch(request.url, {
      method:'GET', headers:request.headers, credentials:'omit', mode:'cors',
      redirect:'follow', signal:entry.controller.signal,
    });
    send({type:'headers', status:response.status, url:response.url,
      headers:Object.fromEntries(response.headers.entries())});
    const reader = response.body?.getReader();
    if (!reader) {
      send({type:'end'});
      return;
    }
    let index = 0;
    while (true) {
      const result = await reader.read();
      if (result.done) break;
      const value = result.value;
      for (let offset = 0; offset < value.length; offset += $_chunkSize) {
        const chunk = value.subarray(offset, Math.min(offset + $_chunkSize, value.length));
        let binary = '';
        for (const byte of chunk) binary += String.fromCharCode(byte);
        const waiting = new Promise(resolve => entry.acks.set(index, resolve));
        send({type:'chunk', index, data:btoa(binary)});
        await waiting;
        if (entry.controller.signal.aborted) return;
        entry.acks.delete(index);
        index++;
      }
    }
    send({type:'end'});
  } catch (error) {
    if (!entry.controller.signal.aborted) {
      send({type:'error', message:String(error)});
    }
  } finally {
    requests.delete(request.id);
  }
})();
})();
''';
  }

  static bool _isSourcePage(String? value) {
    final uri = Uri.tryParse(value ?? '');
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.toLowerCase() == 'missav.ai' &&
        uri.port == 443 &&
        uri.userInfo.isEmpty;
  }

  static bool _isPublicHttps(Uri uri) {
    if (!uri.isAbsolute ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');
    if (host.isEmpty || InternetAddress.tryParse(host) != null) return false;
    final labels = host.split('.');
    if (!host.contains('.') ||
        host.length > 253 ||
        labels.any(
          (label) => !RegExp(
            r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
          ).hasMatch(label),
        )) {
      return false;
    }
    if (labels.every(
      (label) => RegExp(r'^(?:[0-9]+|0x[0-9a-f]+)$').hasMatch(label),
    )) {
      return false;
    }
    const blockedSuffixes = {
      'localhost',
      'local',
      'internal',
      'test',
      'invalid',
      'example',
      'home',
      'lan',
      'onion',
      'arpa',
      'corp',
      'intranet',
      'private',
      'home.arpa',
    };
    if (blockedSuffixes.any(
      (suffix) => host == suffix || host.endsWith('.$suffix'),
    )) {
      return false;
    }
    if (const {
      'example.com',
      'example.net',
      'example.org',
    }.any((suffix) => host == suffix || host.endsWith('.$suffix'))) {
      return false;
    }
    return true;
  }
}

class _MediaRequest {
  _MediaRequest(this.id, this.input, this.streamController);

  final int id;
  final RemoteAssetTransportRequest input;
  final StreamController<List<int>> streamController;
  final headers = Completer<RemoteAssetResponse>();
  final terminated = Completer<Object>();
  Timer? idleTimer;
  _PendingMediaChunk? pendingChunk;
  int? pendingAck;
  var nextChunkIndex = 0;
  var waitingForHeaders = false;
  var headersReceived = false;
  var responseReturned = false;
  var consumerPaused = false;
  var consumerCancelled = false;
  var scriptStarted = false;
  var failed = false;
  var finished = false;
  Object? failure;
}

class _PendingMediaChunk {
  const _PendingMediaChunk(this.index, this.bytes);

  final int index;
  final Uint8List bytes;
}

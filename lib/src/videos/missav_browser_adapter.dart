import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'video_models.dart';

/// Sends source requests through the browser that completed verification.
class MissavBrowserAdapter implements HttpClientAdapter {
  MissavBrowserAdapter({
    required this.runJavaScript,
    required this.currentUrl,
    required this.navigateDocument,
    required this.disposeBrowser,
  }) : _isJable = false;

  MissavBrowserAdapter.jable({
    required this.runJavaScript,
    required this.currentUrl,
    required this.navigateDocument,
    required this.disposeBrowser,
  }) : _isJable = true;

  final bool _isJable;
  final Future<void> Function(String script) runJavaScript;
  final Future<String?> Function() currentUrl;
  final Future<String> Function(Uri uri, Future<void> cancelled)
  navigateDocument;
  final Future<void> Function() disposeBrowser;
  final _pending = <int, _BrowserRequest>{};
  final _nonce = base64UrlEncode(
    List<int>.generate(24, (_) => Random.secure().nextInt(256)),
  );
  var _nextId = 0;
  var _closed = false;
  Future<void>? _cleanup;
  Future<void> _queue = Future<void>.value();

  bool get isClosed => _closed;
  Future<void> get whenClosed => _cleanup ?? Future.value();

  static const channelName = 'KikoMissavHttp';
  static const _requestTimeout = Duration(seconds: 30);
  static const jableChannelName = 'KikoJableHttp';

  String get _origin => _isJable ? 'https://jable.tv' : 'https://missav.ai';
  String get _channelName => _isJable ? jableChannelName : channelName;
  String get _requestMap =>
      _isJable ? '__kikoJableRequests' : '__kikoMissavRequests';

  bool _isSource(String? value) {
    final uri = Uri.tryParse(value ?? '');
    return uri?.scheme == 'https' &&
        uri?.host == (_isJable ? 'jable.tv' : 'missav.ai') &&
        uri?.port == 443 &&
        uri?.userInfo.isEmpty == true;
  }

  VideoSourceException _unsupported(String operation, String url) => _isJable
      ? VideoSourceException(
          'Browser $operation outside Jable are not supported.',
          sourceKey: 'jable',
          sourceUrl: url,
        )
      : MissavUnsupportedException(
          capability: 'browser $operation outside MissAV',
          sourceUrl: url,
        );

  VideoSourceException _verificationRequired(String url) => _isJable
      ? JableVerificationRequiredException(sourceUrl: url)
      : MissavVerificationRequiredException(sourceUrl: url);

  void receiveMessage(Object? message, {String? origin}) {
    if (_closed || (origin != null && origin != _origin)) return;
    try {
      final data = message is String ? jsonDecode(message) : message;
      if (data is! Map ||
          data['nonce'] != _nonce ||
          data['origin'] != _origin ||
          data['id'] is! int) {
        return;
      }
      if (data['error'] != true &&
          (data['status'] is! int ||
              data['url'] is! String ||
              data['body'] is! String ||
              data['headers'] is! Map)) {
        return;
      }
      final completer = _pending[data['id']]?.result;
      if (completer != null && !completer.isCompleted) {
        completer.complete({
          'error': data['error'],
          'status': data['status'],
          'url': data['url'],
          'body': data['body'],
          'headers': data['headers'],
        });
      }
    } on FormatException {
      // The page may send unrelated channel messages.
    }
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!_isSource(options.uri.toString())) {
      throw _unsupported('requests', options.uri.toString());
    }
    final id = ++_nextId;
    final operation = _BrowserRequest(options);
    _pending[id] = operation;
    unawaited(cancelFuture?.then((_) => _cancel(id)));
    try {
      final responseFuture = _runExclusive<Object?>(id, operation, () async {
        unawaited(
          _send(id, operation, requestStream).catchError((
            Object error,
            StackTrace trace,
          ) {
            _completeError(operation, error, trace);
          }),
        );
        try {
          return await operation.result.future;
        } finally {
          final cleanup = operation.cleanup;
          if (cleanup != null) await cleanup;
        }
      });
      final data = await Future.any<Object?>([
        responseFuture,
        operation.result.future,
      ]);
      if (data is! Map) {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'Browser source returned an invalid response',
        );
      }
      if (data['error'] == true) {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'Browser source request failed',
        );
      }
      if (!_isSource(data['url'] as String?)) {
        throw _unsupported('redirects', options.uri.toString());
      }
      final responseHeaders = data['headers'] as Map? ?? const {};
      return ResponseBody.fromString(
        data['body'] as String,
        data['status'] as int,
        headers: responseHeaders.map(
          (key, value) => MapEntry('$key', ['$value']),
        ),
      );
    } finally {
      _pending.remove(id);
    }
  }

  /// Navigates the shared browser to a source HTML document and returns its
  /// rendered markup. API calls continue to use [fetch].
  Future<String> loadDocument(Uri uri, {CancelToken? cancelToken}) async {
    if (!_isSource(uri.toString())) {
      throw _unsupported('documents', uri.toString());
    }
    final id = ++_nextId;
    final options = RequestOptions(
      path: uri.toString(),
      method: 'GET',
      cancelToken: cancelToken,
    );
    final operation = _BrowserRequest(options, isDocument: true);
    _pending[id] = operation;
    if (cancelToken != null) {
      unawaited(cancelToken.whenCancel.then((_) => _cancel(id)));
    }
    try {
      final documentFuture = _runExclusive<String>(id, operation, () async {
        operation.sent = true;
        late final String body;
        try {
          body = await navigateDocument(uri, operation.cancelSignal.future);
        } catch (error, trace) {
          _checkActive(id, operation);
          Error.throwWithStackTrace(error, trace);
        }
        _checkActive(id, operation);
        return body;
      });
      return await Future.any<String>([
        documentFuture,
        operation.result.future.then((value) => value as String),
      ]);
    } finally {
      _pending.remove(id);
    }
  }

  Future<T> _runExclusive<T>(
    int id,
    _BrowserRequest operation,
    Future<T> Function() action,
  ) {
    final previous = _queue;
    final release = Completer<void>();
    _queue = release.future;
    final timeout = operation.options.receiveTimeout ?? _requestTimeout;
    // Allow one default request to finish before timing out in the queue.
    final queueTimeout = timeout + _requestTimeout;
    final waitingTimer = Timer(queueTimeout, () {
      _finishOperation(
        id,
        operation,
        DioException.receiveTimeout(
          timeout: queueTimeout,
          requestOptions: operation.options,
        ),
      );
    });
    operation.result.future.whenComplete(waitingTimer.cancel).ignore();
    return () async {
      await previous;
      waitingTimer.cancel();
      try {
        _checkActive(id, operation);
        final timer = Timer(timeout, () {
          _finishOperation(
            id,
            operation,
            DioException.receiveTimeout(
              timeout: timeout,
              requestOptions: operation.options,
            ),
          );
        });
        try {
          return await action();
        } finally {
          timer.cancel();
        }
      } finally {
        if (!release.isCompleted) release.complete();
      }
    }();
  }

  Future<void> _send(
    int id,
    _BrowserRequest operation,
    Stream<Uint8List>? requestStream,
  ) async {
    _checkActive(id, operation);
    final url = await currentUrl();
    _checkActive(id, operation);
    if (!_isSource(url)) {
      throw _verificationRequired(operation.options.uri.toString());
    }
    final body = requestStream == null
        ? null
        : await utf8.decodeStream(requestStream);
    _checkActive(id, operation);
    final options = operation.options;
    final headers = <String, String>{};
    for (final entry in options.headers.entries) {
      final key = entry.key.toLowerCase();
      if (const {
        'accept',
        'content-type',
        'x-requested-with',
        'x-xsrf-token',
      }.contains(key)) {
        if (key == 'x-xsrf-token' &&
            const ['GET', 'HEAD'].contains(options.method)) {
          continue;
        }
        headers[key] = '${entry.value}';
      }
    }
    final request = jsonEncode({
      'id': id,
      'nonce': _nonce,
      'url': options.uri.toString(),
      'method': options.method,
      'headers': headers,
      'body': body,
    });
    final script =
        '''
(() => {
const request = $request;
const send = data => {
  const message = {...data, id:request.id, nonce:request.nonce, origin:location.origin};
  if (window.desktopWebview) {
    window.desktopWebview.postMessage('$_channelName', message);
  } else {
    window.$_channelName.postMessage(JSON.stringify(message));
  }
};
if (location.origin !== '$_origin' || new URL(request.url).origin !== '$_origin') return;
const controllers = window.$_requestMap ||= new Map();
const controller = new AbortController();
controllers.set(request.id, controller);
const headers = request.headers;
if (request.method !== 'GET' && request.method !== 'HEAD') {
  const token = document.cookie.split(';').map(value => value.trim()).find(value => value.startsWith('XSRF-TOKEN='));
  if (token) headers['x-xsrf-token'] = decodeURIComponent(token.substring('XSRF-TOKEN='.length));
}
fetch(request.url, {
  method: request.method, headers,
  ...(request.method === 'GET' || request.method === 'HEAD' ? {} : {body:request.body}),
  credentials:'same-origin', mode:'same-origin', redirect:'follow',
  signal:controller.signal,
}).then(async response => {
  const body = await response.text();
  send({status:response.status, url:response.url, headers:Object.fromEntries(response.headers), body});
}).catch(() => send({error:true})).finally(() => controllers.delete(request.id));
})();
''';
    _checkActive(id, operation);
    operation.sent = true;
    await runJavaScript(script);
  }

  void _checkActive(int id, _BrowserRequest operation) {
    final terminalError = operation.terminalError;
    if (terminalError != null) {
      Error.throwWithStackTrace(
        terminalError,
        operation.terminalStackTrace ?? StackTrace.current,
      );
    }
    if (_closed || _pending[id] != operation) {
      throw DioException.connectionError(
        requestOptions: operation.options,
        reason: 'Browser connection is no longer available',
      );
    }
    if (operation.cancelled ||
        operation.options.cancelToken?.isCancelled == true) {
      throw DioException.requestCancelled(
        requestOptions: operation.options,
        reason: 'Source request cancelled',
      );
    }
  }

  void _cancel(int id) {
    final operation = _pending[id];
    if (operation == null) return;
    _finishOperation(
      id,
      operation,
      DioException.requestCancelled(
        requestOptions: operation.options,
        reason: 'Source request cancelled',
      ),
    );
  }

  void _finishOperation(
    int id,
    _BrowserRequest operation,
    Object error, [
    StackTrace? trace,
  ]) {
    if (operation.result.isCompleted) return;
    operation.cancelled = true;
    operation.terminalError = error;
    operation.terminalStackTrace = trace;
    if (!operation.cancelSignal.isCompleted) operation.cancelSignal.complete();
    if (operation.sent && !operation.isDocument) {
      operation.cleanup = _abort(id);
    }
    if (trace == null) {
      operation.result.completeError(error);
    } else {
      operation.result.completeError(error, trace);
    }
  }

  void _completeError(
    _BrowserRequest operation,
    Object error,
    StackTrace trace,
  ) {
    if (operation.result.isCompleted) return;
    operation.result.completeError(error, trace);
  }

  Future<void> _abort(int id) async {
    if (_closed) return;
    try {
      await runJavaScript('window.$_requestMap?.get($id)?.abort();');
    } catch (_) {
      // A closed browser has already cancelled its fetches.
    }
  }

  @override
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    for (final entry in _pending.entries.toList()) {
      _finishOperation(
        entry.key,
        entry.value,
        DioException.connectionError(
          requestOptions: entry.value.options,
          reason: 'Browser session closed before the request completed',
        ),
      );
    }
    _pending.clear();
    _cleanup = Future<void>.sync(disposeBrowser);
    _cleanup!.ignore();
  }
}

class _BrowserRequest {
  _BrowserRequest(this.options, {this.isDocument = false});

  final RequestOptions options;
  final bool isDocument;
  final result = Completer<Object?>();
  final cancelSignal = Completer<void>();
  Future<void>? cleanup;
  Object? terminalError;
  StackTrace? terminalStackTrace;
  bool sent = false;
  bool cancelled = false;
}

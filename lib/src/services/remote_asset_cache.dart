import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file/file.dart' as file_api;
import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as cm;
import 'package:path/path.dart' as p;

import 'http_byte_range.dart';
import 'http_response_stream.dart';
import 'shared_http_client.dart';
import 'cache_file_transaction.dart';

enum RemoteAssetKind {
  workCover,
  playlistCover,
  contentImage,
  subtitle,
  document,
}

class RemoteAssetKey {
  const RemoteAssetKey({
    required this.serverScope,
    required this.kind,
    required this.identity,
    this.revision,
  });

  final String serverScope;
  final RemoteAssetKind kind;
  final String identity;
  final String? revision;

  factory RemoteAssetKey.forUri({
    required Uri uri,
    required RemoteAssetKind kind,
    String? identity,
    String? revision,
    String? accountScope,
  }) {
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    final port = uri.hasPort && uri.port != defaultPort ? ':${uri.port}' : '';
    final apiIndex = uri.path.indexOf('/api/');
    final basePath = apiIndex > 0 ? uri.path.substring(0, apiIndex) : '';
    final account = accountScope == null || accountScope.isEmpty
        ? ''
        : '|$accountScope';
    return RemoteAssetKey(
      serverScope:
          '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}$port'
          '$basePath$account',
      kind: kind,
      identity: identity ?? canonicalUri(uri),
      revision: revision,
    );
  }

  static String canonicalUri(Uri uri) {
    final query = <String, List<String>>{
      for (final entry in uri.queryParametersAll.entries)
        if (!const {
          'token',
          'access_token',
          'auth',
        }.contains(entry.key.toLowerCase()))
          entry.key: List<String>.of(entry.value)..sort(),
    };
    final sortedKeys = query.keys.toList()..sort();
    return uri
        .replace(
          queryParameters: {
            for (final key in sortedKeys)
              key: query[key]!.length == 1 ? query[key]!.single : query[key]!,
          },
          fragment: '',
        )
        .toString();
  }

  String get canonical =>
      '$serverScope\u0000${kind.name}\u0000$identity\u0000${revision ?? ''}';

  @override
  bool operator ==(Object other) =>
      other is RemoteAssetKey && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;
}

class RemoteAssetRequest {
  const RemoteAssetRequest({
    required this.uri,
    required this.key,
    this.fileExtension = 'asset',
    this.headers = const {},
    this.allowRange = true,
    this.maxAge = const Duration(days: 30),
    this.forceRevalidate = false,
  });

  final Uri uri;
  final RemoteAssetKey key;
  final String fileExtension;
  final Map<String, String> headers;
  final bool allowRange;
  final Duration maxAge;
  final bool forceRevalidate;

  RemoteAssetRequest copyWith({bool? forceRevalidate}) {
    return RemoteAssetRequest(
      uri: uri,
      key: key,
      fileExtension: fileExtension,
      headers: headers,
      allowRange: allowRange,
      maxAge: maxAge,
      forceRevalidate: forceRevalidate ?? this.forceRevalidate,
    );
  }
}

class RemoteAssetProgress {
  const RemoteAssetProgress({required this.receivedBytes, this.totalBytes});

  final int receivedBytes;
  final int? totalBytes;
}

class RemoteAssetCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

class RemoteAssetTransportRequest {
  const RemoteAssetTransportRequest({
    required this.uri,
    required this.headers,
    required this.cancellation,
  });

  final Uri uri;
  final Map<String, String> headers;
  final RemoteAssetCancellation cancellation;
}

class RemoteAssetResponse {
  const RemoteAssetResponse({
    required this.statusCode,
    required this.stream,
    required this.headers,
    this.contentLength,
  });

  final int statusCode;
  final int? contentLength;
  final Map<String, String> headers;
  final Stream<List<int>> stream;

  String? header(String name) => headers[name.toLowerCase()];
}

abstract interface class RemoteAssetTransport {
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest request);
}

class HttpRemoteAssetTransport implements RemoteAssetTransport {
  HttpRemoteAssetTransport({HttpClient? client})
    : _client = client ?? sharedMediaHttpClient;

  final HttpClient _client;

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest input) async {
    final requestFuture = _client.getUrl(input.uri);
    late final HttpClientRequest request;
    try {
      request = await Future.any<HttpClientRequest>([
        requestFuture,
        input.cancellation.whenCancelled.then<HttpClientRequest>(
          (_) => throw const HttpException('Remote asset transfer cancelled'),
        ),
      ]);
    } catch (_) {
      if (input.cancellation.isCancelled) {
        unawaited(_abortWhenReady(requestFuture));
      }
      rethrow;
    }

    applyMediaRequestHeaders(
      request,
      input.uri,
      input.headers,
      forceIdentityEncoding: input.headers.keys.any(
        (name) => name.toLowerCase() == HttpHeaders.rangeHeader,
      ),
    );
    var waitingForResponse = true;
    unawaited(
      input.cancellation.whenCancelled.then((_) {
        if (waitingForResponse) {
          request.abort(const HttpException('Remote asset transfer cancelled'));
        }
      }),
    );
    if (input.cancellation.isCancelled) {
      request.abort(const HttpException('Remote asset transfer cancelled'));
    }

    final response = await request.close();
    waitingForResponse = false;
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(',');
    });
    return RemoteAssetResponse(
      statusCode: response.statusCode,
      contentLength: response.contentLength < 0 ? null : response.contentLength,
      headers: headers,
      stream: cancellableHttpResponseStream(
        request: request,
        response: response,
        whenCancelled: input.cancellation.whenCancelled,
        isCancelled: () => input.cancellation.isCancelled,
        cancellationMessage: 'Remote asset transfer cancelled',
      ),
    );
  }

  Future<void> _abortWhenReady(Future<HttpClientRequest> requestFuture) async {
    try {
      final request = await requestFuture;
      request.abort(const HttpException('Remote asset transfer cancelled'));
    } catch (_) {
      // The pending connection already failed.
    }
  }
}

abstract interface class RemoteAssetCache {
  RemoteAssetLease acquire(
    RemoteAssetRequest request, {
    bool speculative = false,
  });

  Future<File?> find(RemoteAssetKey key);
  Future<void> invalidate(RemoteAssetKey key);
}

class RemoteAssetLease {
  RemoteAssetLease._(this.file, this.progress, this._release);

  final Future<File> file;
  final Stream<RemoteAssetProgress> progress;
  final Future<void> Function() _release;
  bool _released = false;

  Future<void> release() {
    if (_released) return Future.value();
    _released = true;
    return _release();
  }
}

typedef RemoteAssetDirectoryProvider = Future<Directory> Function();
typedef RemoteAssetChangedCallback = FutureOr<void> Function();

class FileRemoteAssetCache implements RemoteAssetCache {
  FileRemoteAssetCache({
    required RemoteAssetDirectoryProvider directoryProvider,
    RemoteAssetTransport? transport,
    this.onChanged,
  }) : // Keep the public named argument free of the private-field prefix.
       // ignore: prefer_initializing_formals
       _directoryProvider = directoryProvider,
       _transport = transport ?? HttpRemoteAssetTransport() {
    _instances.add(this);
  }

  final RemoteAssetDirectoryProvider _directoryProvider;
  final RemoteAssetTransport _transport;
  final RemoteAssetChangedCallback? onChanged;
  final Map<RemoteAssetKey, _RemoteAssetOperation> _operations = {};
  bool _disposed = false;

  static final Set<FileRemoteAssetCache> _instances = {};
  static final Map<String, int> _activePathCounts = {};

  static bool isCachePathActive(String path) =>
      _activePathCounts.containsKey(p.normalize(path)) ||
      isCacheFileTransactionActive(path);

  static void markCachePathActive(String path) => _markPathActive(path);

  static void unmarkCachePathActive(String path) => _unmarkPathActive(path);

  static Future<void> cancelAllSpeculative() async {
    await Future.wait(
      List<FileRemoteAssetCache>.of(
        _instances,
      ).map((cache) => cache.cancelSpeculative()),
    );
  }

  @override
  RemoteAssetLease acquire(
    RemoteAssetRequest request, {
    bool speculative = false,
  }) {
    if (_disposed) throw StateError('Remote asset cache is disposed');
    var operation = _operations[request.key];
    if (operation == null || operation.cancellation.isCancelled) {
      final previous = operation;
      final created = _RemoteAssetOperation(request);
      Future<void> waitForPrevious() async {
        if (previous == null) return;
        await previous.file.then<void>((_) {}, onError: (_) {});
      }

      created.file = waitForPrevious().then((_) => _download(created));
      created.file = created.file.whenComplete(() {
        created.completed = true;
        if (created.references == 0 && !created.cleanedUp) {
          unawaited(_finishOperation(request.key, created));
        }
      });
      _operations[request.key] = created;
      operation = created;
    }
    final activeOperation = operation;
    activeOperation.references++;
    if (speculative) {
      activeOperation.speculativeReferences++;
    } else {
      activeOperation.visibleReferences++;
    }
    return RemoteAssetLease._(
      activeOperation.file,
      activeOperation.progressController.stream,
      () => _release(request.key, activeOperation, speculative: speculative),
    );
  }

  @override
  Future<File?> find(RemoteAssetKey key) async {
    final snapshot = await _lookup(key);
    return snapshot?.file;
  }

  Future<_RemoteAssetSnapshot?> _lookup(RemoteAssetKey key) async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) return null;
    final metadataFile = File(
      p.join(directory.path, '${_fileStem(key)}.metadata.json'),
    );
    final metadata = await _readMetadata(metadataFile);
    if (metadata == null) return null;
    final file = File(p.join(directory.path, metadata.fileName));
    await recoverCacheFileReplacement(file);
    if (!await file.exists()) return null;
    if (metadata.sourceLength != null &&
        await file.length() != metadata.sourceLength) {
      await file.delete();
      if (await metadataFile.exists()) await metadataFile.delete();
      _notifyChanged();
      return null;
    }
    return _RemoteAssetSnapshot(file: file, metadata: metadata);
  }

  @override
  Future<void> invalidate(RemoteAssetKey key) async {
    final operation = _operations.remove(key);
    operation?.cancellation.cancel();
    if (operation != null) {
      await operation.file.then<void>((_) {}, onError: (_) {});
      operation.completed = true;
      await _finishOperation(key, operation);
    }
    final directory = await _directoryProvider();
    if (!await directory.exists()) return;
    final prefix = '${_fileStem(key)}.';
    await for (final entity in directory.list()) {
      if (entity is File && p.basename(entity.path).startsWith(prefix)) {
        await entity.delete();
      }
    }
    _notifyChanged();
  }

  Future<void> cancelSpeculative() async {
    final cancelled = <Future<File>>[];
    for (final operation in _operations.values) {
      if (operation.visibleReferences == 0 &&
          operation.speculativeReferences > 0 &&
          !operation.completed) {
        operation.cancellation.cancel();
        cancelled.add(operation.file);
      }
    }
    await Future.wait(
      cancelled.map((future) => future.then<void>((_) {}, onError: (_) {})),
    );
  }

  Future<void> clearInactive() async {
    await cancelSpeculative();
    for (final operation in _operations.values) {
      if (operation.references > 0) operation.deleteOnRelease = true;
    }
    final directory = await _directoryProvider();
    if (!await directory.exists()) return;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File && !isCachePathActive(entity.path)) {
        try {
          await entity.delete();
        } on FileSystemException {
          // Another cache consumer may have acquired the file concurrently.
        }
      }
    }
    _notifyChanged();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _instances.remove(this);
    final operations = List<_RemoteAssetOperation>.of(_operations.values);
    _operations.clear();
    for (final operation in operations) {
      operation.cancellation.cancel();
    }
    await Future.wait(
      operations.map(
        (operation) => operation.file.then<void>((_) {}, onError: (_) {}),
      ),
    );
    for (final operation in operations) {
      operation.completed = true;
      await _finishOperation(operation.request.key, operation);
    }
  }

  Future<File> _download(_RemoteAssetOperation operation) async {
    final request = operation.request;
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    final extension = _safeExtension(request.fileExtension);
    final finalFile = File(
      p.join(directory.path, '${_fileStem(request.key)}.$extension'),
    );
    final metadataFile = File(
      p.join(directory.path, '${_fileStem(request.key)}.metadata.json'),
    );
    final partialFile = File('${finalFile.path}.part');
    final partialMetadataFile = File('${partialFile.path}.metadata.json');
    await recoverCacheFileReplacement(finalFile);
    operation.activePaths.addAll({
      finalFile.path,
      metadataFile.path,
      partialFile.path,
      partialMetadataFile.path,
    });
    for (final path in operation.activePaths) {
      _markPathActive(path);
    }
    operation.pathsMarked = true;
    var metadata = await _readMetadata(metadataFile);
    var hasFinalFile = await finalFile.exists();
    if (hasFinalFile &&
        metadata?.sourceLength != null &&
        await finalFile.length() != metadata!.sourceLength) {
      await finalFile.delete();
      if (await metadataFile.exists()) await metadataFile.delete();
      metadata = null;
      hasFinalFile = false;
      _notifyChanged();
    }
    if (!request.forceRevalidate &&
        hasFinalFile &&
        metadata != null &&
        metadata.validTill.isAfter(DateTime.now())) {
      return finalFile;
    }

    var partialMetadata = await _readPartialMetadata(partialMetadataFile);
    var prefixLength = request.allowRange && await partialFile.exists()
        ? await partialFile.length()
        : 0;
    if (!request.allowRange && await partialFile.exists()) {
      await partialFile.delete();
    }
    if (!request.allowRange && await partialMetadataFile.exists()) {
      await partialMetadataFile.delete();
      partialMetadata = null;
    }
    if (prefixLength == 0 && await partialMetadataFile.exists()) {
      await partialMetadataFile.delete();
      partialMetadata = null;
    }
    if (prefixLength > 0 && partialMetadata == null) {
      // A prefix without its source metadata cannot be proven to belong to the
      // current representation. Restarting is the only corruption-safe path.
      await _deletePartialState(partialFile, partialMetadataFile);
      prefixLength = 0;
    }
    if (prefixLength > 0 &&
        partialMetadata != null &&
        (partialMetadata.sourceUri != _canonicalSourceUri(request.uri) ||
            (partialMetadata.sourceLength != null &&
                prefixLength > partialMetadata.sourceLength!))) {
      await _deletePartialState(partialFile, partialMetadataFile);
      prefixLength = 0;
      partialMetadata = null;
    }
    final headers = <String, String>{...request.headers};
    if (request.allowRange) {
      headers['Accept-Encoding'] = 'identity';
      if (prefixLength > 0) {
        headers['Range'] = 'bytes=$prefixLength-';
        final ifRange = partialMetadata?.ifRange;
        if (ifRange != null) headers['If-Range'] = ifRange;
      }
    }
    if (prefixLength == 0 && hasFinalFile && metadata != null) {
      if (metadata.etag != null) {
        headers['If-None-Match'] = metadata.etag!;
      }
      if (metadata.lastModified != null) {
        headers['If-Modified-Since'] = metadata.lastModified!;
      }
    }
    final response = await _transport.open(
      RemoteAssetTransportRequest(
        uri: request.uri,
        headers: headers,
        cancellation: operation.cancellation,
      ),
    );
    int? sourceLength;
    int? expectedResponseLength;
    var append = false;
    if (response.statusCode == HttpStatus.notModified) {
      await response.stream.drain<void>();
      if (!hasFinalFile || metadata == null) {
        throw HttpException(
          'Received 304 without a cached remote asset',
          uri: request.uri,
        );
      }
      if (_isNoStore(response)) {
        operation.deleteOnRelease = true;
        if (await metadataFile.exists()) await metadataFile.delete();
      } else {
        await _writeMetadata(
          metadataFile,
          metadata.copyWith(
            validTill: _resolveRevalidatedValidTill(
              response,
              metadata,
              request.maxAge,
            ),
            etag: response.header(HttpHeaders.etagHeader) ?? metadata.etag,
            lastModified:
                response.header(HttpHeaders.lastModifiedHeader) ??
                metadata.lastModified,
          ),
        );
      }
      await _deletePartialState(partialFile, partialMetadataFile);
      return finalFile;
    } else if (response.statusCode == HttpStatus.partialContent) {
      late final ByteRangeResponsePlan range;
      try {
        range = resolveByteRangeResponse(
          statusCode: response.statusCode,
          requestedStart: prefixLength,
          contentLength: response.contentLength,
          contentRange: response.header(HttpHeaders.contentRangeHeader),
        );
      } on FormatException {
        await response.stream.drain<void>();
        await _deletePartialState(partialFile, partialMetadataFile);
        rethrow;
      }
      if (!_partialRepresentationMatches(
        partialMetadata,
        response,
        range.sourceLength,
      )) {
        await response.stream.drain<void>();
        await _deletePartialState(partialFile, partialMetadataFile);
        throw const FormatException(
          'Remote asset validator changed during a resumed response',
        );
      }
      append = prefixLength > 0;
      sourceLength = range.sourceLength;
      expectedResponseLength = range.responseLength;
    } else if (response.statusCode == HttpStatus.ok) {
      // The origin may ignore Range. Treat a full response as a safe restart.
      prefixLength = 0;
      sourceLength = response.contentLength;
      expectedResponseLength = response.contentLength;
    } else if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      await response.stream.drain<void>();
      late final ByteRangeResponsePlan range;
      try {
        range = resolveByteRangeResponse(
          statusCode: response.statusCode,
          requestedStart: prefixLength,
          contentLength: response.contentLength,
          contentRange: response.header(HttpHeaders.contentRangeHeader),
        );
      } on FormatException {
        await _deletePartialState(partialFile, partialMetadataFile);
        rethrow;
      }
      if (range.kind == ByteRangeResponseKind.alreadyComplete) {
        if (!_partialRepresentationMatches(
          partialMetadata,
          response,
          range.sourceLength,
        )) {
          await _deletePartialState(partialFile, partialMetadataFile);
          throw const FormatException(
            'Remote asset validator changed before range completion',
          );
        }
        final completed = await replaceCacheFile(partialFile, finalFile);
        if (await partialMetadataFile.exists()) {
          await partialMetadataFile.delete();
        }
        await _writeMetadata(
          metadataFile,
          _RemoteAssetMetadata(
            fileName: p.basename(finalFile.path),
            sourceUri: _canonicalSourceUri(request.uri),
            validTill: _resolveValidTill(response, request.maxAge),
            etag:
                response.header(HttpHeaders.etagHeader) ??
                partialMetadata?.etag,
            lastModified:
                response.header(HttpHeaders.lastModifiedHeader) ??
                partialMetadata?.lastModified,
            sourceLength: range.sourceLength!,
            contentType: response.header(HttpHeaders.contentTypeHeader),
          ),
        );
        _notifyChanged();
        return completed;
      }
      await _deletePartialState(partialFile, partialMetadataFile);
      throw HttpException(
        'Remote asset range is not satisfiable',
        uri: request.uri,
      );
    } else {
      await response.stream.drain<void>();
      throw HttpException(
        'Failed to load remote asset (status: ${response.statusCode})',
        uri: request.uri,
      );
    }

    if (_isNoStore(response)) operation.deleteOnRelease = true;
    final responsePartialMetadata = _RemoteAssetPartialMetadata(
      sourceUri: _canonicalSourceUri(request.uri),
      sourceLength: sourceLength,
      etag:
          response.header(HttpHeaders.etagHeader) ??
          (append ? partialMetadata?.etag : null),
      lastModified:
          response.header(HttpHeaders.lastModifiedHeader) ??
          (append ? partialMetadata?.lastModified : null),
    );
    await _writePartialMetadata(partialMetadataFile, responsePartialMetadata);

    final output = await partialFile.open(
      mode: append ? FileMode.writeOnlyAppend : FileMode.write,
    );
    var received = 0;
    var structurallyInvalid = false;
    try {
      await for (final chunk in response.stream) {
        if (operation.cancellation.isCancelled) {
          throw const HttpException('Remote asset transfer cancelled');
        }
        received += chunk.length;
        if (expectedResponseLength != null &&
            received > expectedResponseLength) {
          structurallyInvalid = true;
          throw const FormatException(
            'Remote asset response exceeded its declared length',
          );
        }
        await output.writeFrom(chunk);
        operation.progressController.add(
          RemoteAssetProgress(
            receivedBytes: prefixLength + received,
            totalBytes: sourceLength,
          ),
        );
      }
      await output.flush();
    } finally {
      await output.close();
      if (structurallyInvalid) {
        await _deletePartialState(partialFile, partialMetadataFile);
      }
    }
    if (expectedResponseLength != null && received != expectedResponseLength) {
      throw const HttpException(
        'Remote asset response ended before declared length',
      );
    }
    final actualLength = await partialFile.length();
    final completedLength = sourceLength ?? actualLength;
    if (actualLength != completedLength) {
      if (actualLength > completedLength) {
        await _deletePartialState(partialFile, partialMetadataFile);
      }
      throw const HttpException('Remote asset response is incomplete');
    }
    final completed = await replaceCacheFile(partialFile, finalFile);
    if (await partialMetadataFile.exists()) await partialMetadataFile.delete();
    if (_isNoStore(response)) {
      operation.deleteOnRelease = true;
      if (await metadataFile.exists()) await metadataFile.delete();
    } else {
      await _writeMetadata(
        metadataFile,
        _RemoteAssetMetadata(
          fileName: p.basename(finalFile.path),
          sourceUri: _canonicalSourceUri(request.uri),
          validTill: _resolveValidTill(response, request.maxAge),
          etag: response.header(HttpHeaders.etagHeader),
          lastModified: response.header(HttpHeaders.lastModifiedHeader),
          sourceLength: completedLength,
          contentType: response.header(HttpHeaders.contentTypeHeader),
        ),
      );
    }
    _notifyChanged();
    return completed;
  }

  DateTime _resolveValidTill(RemoteAssetResponse response, Duration fallback) {
    final cacheControl = response.header(HttpHeaders.cacheControlHeader);
    if (cacheControl != null) {
      if (RegExp(
        r'(^|,)\s*(no-cache|must-revalidate)\s*(,|$)',
        caseSensitive: false,
      ).hasMatch(cacheControl)) {
        return DateTime.now();
      }
      final match = RegExp(
        r'(^|,)\s*max-age=(\d+)',
        caseSensitive: false,
      ).firstMatch(cacheControl);
      if (match != null) {
        return DateTime.now().add(
          Duration(seconds: int.parse(match.group(2)!)),
        );
      }
    }
    final expires = response.header(HttpHeaders.expiresHeader);
    if (expires != null) {
      try {
        return HttpDate.parse(expires);
      } on FormatException {
        // Fall through to the resource policy for invalid server metadata.
      }
    }
    return DateTime.now().add(fallback);
  }

  DateTime _resolveRevalidatedValidTill(
    RemoteAssetResponse response,
    _RemoteAssetMetadata metadata,
    Duration fallback,
  ) {
    if (response.header(HttpHeaders.cacheControlHeader) == null &&
        response.header(HttpHeaders.expiresHeader) == null) {
      return metadata.validTill.isAfter(DateTime.now())
          ? metadata.validTill
          : DateTime.now();
    }
    return _resolveValidTill(response, fallback);
  }

  bool _isNoStore(RemoteAssetResponse response) {
    final value = response.header(HttpHeaders.cacheControlHeader) ?? '';
    return value
        .split(',')
        .any((directive) => directive.trim().toLowerCase() == 'no-store');
  }

  String _canonicalSourceUri(Uri uri) {
    return RemoteAssetKey.canonicalUri(uri);
  }

  Future<_RemoteAssetMetadata?> _readMetadata(File file) async {
    await recoverCacheFileReplacement(file);
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      return _RemoteAssetMetadata.fromJson(value as Map<String, dynamic>);
    } catch (_) {
      await file.delete();
      return null;
    }
  }

  Future<_RemoteAssetPartialMetadata?> _readPartialMetadata(File file) async {
    await recoverCacheFileReplacement(file);
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      return _RemoteAssetPartialMetadata.fromJson(
        value as Map<String, dynamic>,
      );
    } catch (_) {
      await file.delete();
      return null;
    }
  }

  Future<void> _writePartialMetadata(
    File file,
    _RemoteAssetPartialMetadata metadata,
  ) async {
    final temporary = File('${file.path}.tmp');
    _markPathActive(temporary.path);
    try {
      await temporary.writeAsString(jsonEncode(metadata.toJson()), flush: true);
      await replaceCacheFile(temporary, file);
    } finally {
      _unmarkPathActive(temporary.path);
    }
  }

  Future<void> _deletePartialState(File partial, File metadata) async {
    if (await partial.exists()) await partial.delete();
    if (await metadata.exists()) await metadata.delete();
  }

  bool _partialRepresentationMatches(
    _RemoteAssetPartialMetadata? partial,
    RemoteAssetResponse response,
    int? sourceLength,
  ) {
    if (partial == null) return true;
    final responseEtag = response.header(HttpHeaders.etagHeader);
    if (partial.etag != null &&
        responseEtag != null &&
        partial.etag != responseEtag) {
      return false;
    }
    final responseLastModified = response.header(
      HttpHeaders.lastModifiedHeader,
    );
    if (partial.lastModified != null &&
        responseLastModified != null &&
        partial.lastModified != responseLastModified) {
      return false;
    }
    return partial.sourceLength == null ||
        sourceLength == null ||
        partial.sourceLength == sourceLength;
  }

  Future<void> _writeMetadata(File file, _RemoteAssetMetadata metadata) async {
    final temporary = File('${file.path}.tmp');
    _markPathActive(temporary.path);
    try {
      await temporary.writeAsString(jsonEncode(metadata.toJson()), flush: true);
      await replaceCacheFile(temporary, file);
    } finally {
      _unmarkPathActive(temporary.path);
    }
  }

  Future<File> _storeBytes(
    RemoteAssetRequest request,
    Uint8List bytes, {
    String? etag,
    Duration? maxAge,
  }) {
    return _storeStream(
      request,
      Stream<List<int>>.value(bytes),
      sourceLength: bytes.length,
      etag: etag,
      maxAge: maxAge,
    );
  }

  Future<File> _storeStream(
    RemoteAssetRequest request,
    Stream<List<int>> stream, {
    int? sourceLength,
    String? etag,
    Duration? maxAge,
  }) async {
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    final stem = _fileStem(request.key);
    final finalFile = File(
      p.join(directory.path, '$stem.${_safeExtension(request.fileExtension)}'),
    );
    final partialFile = File('${finalFile.path}.part');
    final output = await partialFile.open(mode: FileMode.write);
    var received = 0;
    _markPathActive(partialFile.path);
    try {
      await for (final chunk in stream) {
        await output.writeFrom(chunk);
        received += chunk.length;
      }
      await output.flush();
    } finally {
      await output.close();
      _unmarkPathActive(partialFile.path);
    }
    if (sourceLength != null && received != sourceLength) {
      throw const HttpException('Stored remote asset has an invalid length');
    }
    final completed = await replaceCacheFile(partialFile, finalFile);
    await _writeMetadata(
      File(p.join(directory.path, '$stem.metadata.json')),
      _RemoteAssetMetadata(
        fileName: p.basename(finalFile.path),
        sourceUri: _canonicalSourceUri(request.uri),
        validTill: DateTime.now().add(maxAge ?? request.maxAge),
        etag: etag,
        sourceLength: received,
      ),
    );
    _notifyChanged();
    return completed;
  }

  Future<void> _release(
    RemoteAssetKey key,
    _RemoteAssetOperation operation, {
    required bool speculative,
  }) async {
    if (operation.references > 0) operation.references--;
    if (speculative) {
      if (operation.speculativeReferences > 0) {
        operation.speculativeReferences--;
      }
    } else if (operation.visibleReferences > 0) {
      operation.visibleReferences--;
    }
    if (operation.references != 0) return;
    if (!operation.completed) operation.cancellation.cancel();
    if (operation.completed) await _finishOperation(key, operation);
  }

  Future<void> _finishOperation(
    RemoteAssetKey key,
    _RemoteAssetOperation operation,
  ) async {
    if (operation.cleanedUp) return;
    operation.cleanedUp = true;
    if (operation.pathsMarked) {
      for (final path in operation.activePaths) {
        _unmarkPathActive(path);
      }
      operation.pathsMarked = false;
    }
    if (operation.deleteOnRelease) {
      for (final path in operation.activePaths) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // The lease is already released; a later cache cleanup can retry.
        }
      }
      _notifyChanged();
    }
    if (identical(_operations[key], operation)) _operations.remove(key);
    if (!operation.progressController.isClosed) {
      await operation.progressController.close();
    }
  }

  String _fileStem(RemoteAssetKey key) =>
      base64Url.encode(utf8.encode(key.canonical)).replaceAll('=', '');

  void _notifyChanged() {
    final callback = onChanged;
    if (callback == null) return;
    unawaited(Future<void>.sync(callback));
  }

  static void _markPathActive(String path) {
    final normalized = p.normalize(path);
    _activePathCounts.update(
      normalized,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  static void _unmarkPathActive(String path) {
    final normalized = p.normalize(path);
    final count = _activePathCounts[normalized];
    if (count == null || count <= 1) {
      _activePathCounts.remove(normalized);
    } else {
      _activePathCounts[normalized] = count - 1;
    }
  }

  String _safeExtension(String value) {
    final normalized = value.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    return normalized.isEmpty ? 'asset' : normalized;
  }
}

class _RemoteAssetOperation {
  _RemoteAssetOperation(this.request);

  final RemoteAssetRequest request;
  final RemoteAssetCancellation cancellation = RemoteAssetCancellation();
  final StreamController<RemoteAssetProgress> progressController =
      StreamController<RemoteAssetProgress>.broadcast();
  late Future<File> file;
  int references = 0;
  int speculativeReferences = 0;
  int visibleReferences = 0;
  bool completed = false;
  bool deleteOnRelease = false;
  bool pathsMarked = false;
  bool cleanedUp = false;
  final Set<String> activePaths = {};
}

class RemoteAssetImageCacheManager implements cm.BaseCacheManager {
  RemoteAssetImageCacheManager({
    required FileRemoteAssetCache cache,
    String? Function()? accountScopeProvider,
    cm.BaseCacheManager? legacyCacheManager,
  }) : // Keep the public named arguments free of private-field prefixes.
       // ignore: prefer_initializing_formals
       _cache = cache,
       _accountScopeProvider = accountScopeProvider ?? _emptyAccountScope,
       // ignore: prefer_initializing_formals
       _legacyCacheManager = legacyCacheManager;

  static const LocalFileSystem _fileSystem = LocalFileSystem();

  final FileRemoteAssetCache _cache;
  final String? Function() _accountScopeProvider;
  final cm.BaseCacheManager? _legacyCacheManager;
  final Set<WeakReference<file_api.File>> _ephemeralFiles = {};
  final Map<String, RemoteAssetKey> _aliases = {};
  int _ephemeralFileSequence = 0;

  static String? _emptyAccountScope() => null;

  RemoteAssetLease acquireFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool speculative = false,
    bool forceRevalidate = false,
  }) {
    return _cache.acquire(
      _requestFor(
        url,
        key: key,
        headers: headers,
        forceRevalidate: forceRevalidate,
      ),
      speculative: speculative,
    );
  }

  @override
  Future<cm.FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) async {
    final request = _requestFor(
      url,
      key: key,
      headers: authHeaders,
      forceRevalidate: force,
    );
    final lease = _cache.acquire(request);
    try {
      final file = await lease.file;
      final snapshot = await _cache._lookup(request.key);
      if (_cache._operations[request.key]?.deleteOnRelease == true) {
        final callerFile = await _copyEphemeralFile(file);
        return _fileInfoForFile(
          callerFile,
          snapshot,
          url,
          cm.FileSource.Online,
        );
      }
      return _fileInfo(file, snapshot, url, cm.FileSource.Online);
    } finally {
      await lease.release();
    }
  }

  @override
  Future<void> emptyCache() async {
    await _cache.clearInactive();
    await _clearEphemeralFiles();
    await _legacyCacheManager?.emptyCache();
  }

  @override
  @Deprecated('Prefer to use getFileStream')
  Stream<cm.FileInfo> getFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) {
    return getFileStream(
      url,
      key: key,
      headers: headers,
    ).where((event) => event is cm.FileInfo).cast<cm.FileInfo>();
  }

  @override
  Future<cm.FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    final resolved = _aliases[key];
    if (resolved == null) return _legacyCacheManager?.getFileFromCache(key);
    final snapshot = await _cache._lookup(resolved);
    if (snapshot == null) return null;
    return _fileInfo(
      snapshot.file,
      snapshot,
      snapshot.metadata.sourceUri,
      cm.FileSource.Cache,
    );
  }

  @override
  Future<cm.FileInfo?> getFileFromMemory(String key) {
    return getFileFromCache(key);
  }

  @override
  Stream<cm.FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    final request = _requestFor(url, key: key, headers: headers);
    var snapshot = await _cache._lookup(request.key);
    snapshot ??= await _adoptLegacy(url, key, request);
    if (snapshot != null) {
      yield _fileInfo(snapshot.file, snapshot, url, cm.FileSource.Cache);
      if (snapshot.metadata.validTill.isAfter(DateTime.now())) return;
    }
    final hadStaleFile = snapshot != null;

    final refreshRequest = snapshot == null
        ? request
        : request.copyWith(forceRevalidate: true);
    final lease = _cache.acquire(refreshRequest);
    final controller = StreamController<cm.FileResponse>();
    final progressSubscription = withProgress
        ? lease.progress.listen((progress) {
            controller.add(
              cm.DownloadProgress(
                url,
                progress.totalBytes,
                progress.receivedBytes,
              ),
            );
          }, onError: controller.addError)
        : null;
    unawaited(
      lease.file.then(
        (file) async {
          final refreshed = await _cache._lookup(request.key);
          final callerFile = refreshed == null
              ? await _copyEphemeralFile(file)
              : _fileSystem.file(file.path);
          controller.add(
            _fileInfoForFile(callerFile, refreshed, url, cm.FileSource.Online),
          );
          await controller.close();
        },
        onError: (Object error, StackTrace stackTrace) async {
          if (!hadStaleFile) controller.addError(error, stackTrace);
          await controller.close();
        },
      ),
    );
    try {
      yield* controller.stream;
    } finally {
      await progressSubscription?.cancel();
      await lease.release();
    }
  }

  @override
  Future<file_api.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async {
    final request = _requestFor(url, key: key, headers: headers);
    final snapshot =
        await _cache._lookup(request.key) ??
        await _adoptLegacy(url, key, request);
    if (snapshot != null) return _fileSystem.file(snapshot.file.path);
    final lease = _cache.acquire(request);
    try {
      final file = await lease.file;
      if (_cache._operations[request.key]?.deleteOnRelease == true) {
        return _copyEphemeralFile(file);
      }
      return _fileSystem.file(file.path);
    } finally {
      await lease.release();
    }
  }

  @override
  Future<file_api.File> putFile(
    String url,
    Uint8List fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) async {
    final request = _requestFor(
      url,
      key: key,
      fileExtension: fileExtension,
      maxAge: maxAge,
    );
    final stored = await _cache._storeBytes(
      request,
      fileBytes,
      etag: eTag,
      maxAge: maxAge,
    );
    return _fileSystem.file(stored.path);
  }

  @override
  Future<file_api.File> putFileStream(
    String url,
    Stream<List<int>> source, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) async {
    final request = _requestFor(
      url,
      key: key,
      fileExtension: fileExtension,
      maxAge: maxAge,
    );
    final stored = await _cache._storeStream(
      request,
      source,
      etag: eTag,
      maxAge: maxAge,
    );
    return _fileSystem.file(stored.path);
  }

  @override
  Future<void> removeFile(String key) async {
    final resolved = _aliases.remove(key);
    if (resolved != null) await _cache.invalidate(resolved);
    await _legacyCacheManager?.removeFile(key);
  }

  @override
  Future<void> dispose() async {
    await _clearEphemeralFiles();
    await _legacyCacheManager?.dispose();
  }

  RemoteAssetRequest _requestFor(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool forceRevalidate = false,
    String? fileExtension,
    Duration maxAge = const Duration(days: 7),
  }) {
    final uri = Uri.parse(url);
    final parsed = _parseAlias(uri, key);
    final assetKey = RemoteAssetKey.forUri(
      uri: uri,
      kind: parsed.kind,
      identity: parsed.identity,
      revision: parsed.revision,
      accountScope: _accountScopeProvider(),
    );
    _aliases[key ?? url] = assetKey;
    return RemoteAssetRequest(
      uri: uri,
      key: assetKey,
      fileExtension: fileExtension ?? _imageExtension(uri),
      headers: headers ?? const {},
      maxAge: maxAge,
      forceRevalidate: forceRevalidate,
    );
  }

  _ImageAlias _parseAlias(Uri uri, String? key) {
    if (key != null && key.startsWith('work_cover_')) {
      return _ImageAlias(
        kind: RemoteAssetKind.workCover,
        identity: key.substring('work_cover_'.length),
      );
    }
    if (key != null && key.startsWith('playlist_cover_')) {
      final value = key.substring('playlist_cover_'.length);
      final separator = value.indexOf('|');
      return _ImageAlias(
        kind: RemoteAssetKind.playlistCover,
        identity: separator < 0 ? value : value.substring(0, separator),
        revision: separator < 0 ? null : value.substring(separator + 1),
      );
    }
    if (key != null && key.startsWith('content_image_')) {
      return _ImageAlias(
        kind: RemoteAssetKind.contentImage,
        identity: key.substring('content_image_'.length),
      );
    }
    final coverMatch = RegExp(r'/api/cover/(\d+)$').firstMatch(uri.path);
    if (coverMatch != null) {
      return _ImageAlias(
        kind: RemoteAssetKind.workCover,
        identity: coverMatch.group(1)!,
      );
    }
    return _ImageAlias(
      kind: RemoteAssetKind.contentImage,
      identity: RemoteAssetKey.canonicalUri(uri),
    );
  }

  Future<_RemoteAssetSnapshot?> _adoptLegacy(
    String url,
    String? key,
    RemoteAssetRequest request,
  ) async {
    final legacy = _legacyCacheManager;
    if (legacy == null) return null;
    final info = await legacy.getFileFromCache(key ?? url);
    if (info == null ||
        RemoteAssetKey.canonicalUri(Uri.parse(info.originalUrl)) !=
            RemoteAssetKey.canonicalUri(Uri.parse(url))) {
      return null;
    }
    final stored = await _cache._storeStream(
      request,
      info.file.openRead(),
      sourceLength: await info.file.length(),
      maxAge: info.validTill.difference(DateTime.now()),
    );
    return _RemoteAssetSnapshot(
      file: stored,
      metadata: (await _cache._lookup(request.key))!.metadata,
    );
  }

  cm.FileInfo _fileInfo(
    File file,
    _RemoteAssetSnapshot? snapshot,
    String url,
    cm.FileSource source,
  ) {
    return _fileInfoForFile(_fileSystem.file(file.path), snapshot, url, source);
  }

  cm.FileInfo _fileInfoForFile(
    file_api.File file,
    _RemoteAssetSnapshot? snapshot,
    String url,
    cm.FileSource source,
  ) {
    return cm.FileInfo(
      file,
      source,
      snapshot?.metadata.validTill ?? DateTime.now(),
      url,
    );
  }

  Future<file_api.File> _copyEphemeralFile(File source) async {
    _ephemeralFiles.removeWhere((reference) => reference.target == null);
    final extension = p.extension(source.path);
    final fileSystem = MemoryFileSystem();
    final target = fileSystem.file(
      'remote_asset_${_ephemeralFileSequence++}$extension',
    );
    await target.writeAsBytes(await source.readAsBytes(), flush: true);
    _ephemeralFiles.add(WeakReference(target));
    return target;
  }

  Future<void> _clearEphemeralFiles() async {
    for (final reference in _ephemeralFiles) {
      final file = reference.target;
      if (file == null) continue;
      if (await file.exists()) await file.delete();
    }
    _ephemeralFiles.clear();
  }

  String _imageExtension(Uri uri) {
    final extension = p.extension(uri.path).replaceFirst('.', '').toLowerCase();
    return const {
          'jpg',
          'jpeg',
          'png',
          'gif',
          'webp',
          'bmp',
          'avif',
        }.contains(extension)
        ? extension
        : 'image';
  }
}

class _ImageAlias {
  const _ImageAlias({
    required this.kind,
    required this.identity,
    this.revision,
  });

  final RemoteAssetKind kind;
  final String identity;
  final String? revision;
}

class _RemoteAssetSnapshot {
  const _RemoteAssetSnapshot({required this.file, required this.metadata});

  final File file;
  final _RemoteAssetMetadata metadata;
}

class _RemoteAssetPartialMetadata {
  const _RemoteAssetPartialMetadata({
    required this.sourceUri,
    required this.sourceLength,
    this.etag,
    this.lastModified,
  });

  factory _RemoteAssetPartialMetadata.fromJson(Map<String, dynamic> json) {
    return _RemoteAssetPartialMetadata(
      sourceUri: json['sourceUri'] as String,
      sourceLength: json['sourceLength'] as int?,
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
    );
  }

  final String sourceUri;
  final int? sourceLength;
  final String? etag;
  final String? lastModified;

  String? get ifRange {
    final candidate = etag;
    if (candidate != null && !candidate.startsWith('W/')) return candidate;
    return lastModified;
  }

  Map<String, Object?> toJson() => {
    'sourceUri': sourceUri,
    'sourceLength': sourceLength,
    'etag': etag,
    'lastModified': lastModified,
  };
}

class _RemoteAssetMetadata {
  const _RemoteAssetMetadata({
    required this.fileName,
    required this.sourceUri,
    required this.validTill,
    this.etag,
    this.lastModified,
    this.sourceLength,
    this.contentType,
  });

  factory _RemoteAssetMetadata.fromJson(Map<String, dynamic> json) {
    return _RemoteAssetMetadata(
      fileName: json['fileName'] as String,
      sourceUri: json['sourceUri'] as String,
      validTill: DateTime.fromMillisecondsSinceEpoch(json['validTill'] as int),
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
      sourceLength: json['sourceLength'] as int?,
      contentType: json['contentType'] as String?,
    );
  }

  final String fileName;
  final String sourceUri;
  final DateTime validTill;
  final String? etag;
  final String? lastModified;
  final int? sourceLength;
  final String? contentType;

  _RemoteAssetMetadata copyWith({
    DateTime? validTill,
    String? etag,
    String? lastModified,
  }) {
    return _RemoteAssetMetadata(
      fileName: fileName,
      sourceUri: sourceUri,
      validTill: validTill ?? this.validTill,
      etag: etag ?? this.etag,
      lastModified: lastModified ?? this.lastModified,
      sourceLength: sourceLength,
      contentType: contentType,
    );
  }

  Map<String, Object?> toJson() => {
    'fileName': fileName,
    'sourceUri': sourceUri,
    'validTill': validTill.millisecondsSinceEpoch,
    'etag': etag,
    'lastModified': lastModified,
    'sourceLength': sourceLength,
    'contentType': contentType,
  };
}

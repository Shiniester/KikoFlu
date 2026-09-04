import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

// ignore_for_file: experimental_member_use

import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import 'audio_cache_files.dart';
import 'cache_file_transaction.dart';
import 'http_byte_range.dart';
import 'http_response_stream.dart';
import 'shared_http_client.dart';
import 'log_service.dart';

class AudioTransferRequest {
  const AudioTransferRequest({required this.uri, required this.hash});

  final Uri uri;
  final String hash;
}

sealed class AudioPlaybackTarget {
  const AudioPlaybackTarget();
}

final class AudioFilePlaybackTarget extends AudioPlaybackTarget {
  const AudioFilePlaybackTarget(this.path);

  final String path;
}

final class AudioStreamPlaybackTarget extends AudioPlaybackTarget {
  const AudioStreamPlaybackTarget(this.request);

  final AudioTransferRequest request;
}

/// Keeps a completed cache file out of eviction while a player owns it.
final class AudioCacheFileLease {
  AudioCacheFileLease._(this.path, this._release);

  final String path;
  final void Function() _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class AudioTransferCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

class AudioRangeResponse {
  const AudioRangeResponse({
    required this.statusCode,
    required this.stream,
    this.contentLength,
    this.contentRange,
    this.contentType,
  });

  final int statusCode;
  final int? contentLength;
  final String? contentRange;
  final String? contentType;
  final Stream<List<int>> stream;
}

abstract interface class AudioRangeTransport {
  Future<AudioRangeResponse> open({
    required Uri uri,
    required int start,
    int? end,
    required Map<String, String> headers,
    required AudioTransferCancellation cancellation,
  });
}

class HttpAudioRangeTransport implements AudioRangeTransport {
  HttpAudioRangeTransport({HttpClient? client})
    : _client = client ?? sharedMediaHttpClient;
  final HttpClient _client;

  @override
  Future<AudioRangeResponse> open({
    required Uri uri,
    required int start,
    int? end,
    required Map<String, String> headers,
    required AudioTransferCancellation cancellation,
  }) async {
    final requestFuture = _client.getUrl(uri);
    late final HttpClientRequest request;
    try {
      request = await Future.any<HttpClientRequest>([
        requestFuture,
        cancellation.whenCancelled.then<HttpClientRequest>(
          (_) => throw const HttpException('Audio transfer cancelled'),
        ),
      ]);
    } catch (_) {
      if (cancellation.isCancelled) {
        unawaited(_abortRequestWhenReady(requestFuture));
      }
      rethrow;
    }
    if (start != 0 || end != null) {
      final inclusiveEnd = end == null ? '' : '${end - 1}';
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$start-$inclusiveEnd',
      );
    }
    applyMediaRequestHeaders(
      request,
      uri,
      headers,
      forceIdentityEncoding: true,
    );

    var waitingForResponse = true;
    unawaited(
      cancellation.whenCancelled.then((_) {
        if (waitingForResponse) {
          request.abort(const HttpException('Audio transfer cancelled'));
        }
      }),
    );
    if (cancellation.isCancelled) {
      request.abort(const HttpException('Audio transfer cancelled'));
    }

    final response = await request.close();
    waitingForResponse = false;
    if ((response.statusCode < 200 || response.statusCode >= 300) &&
        response.statusCode != HttpStatus.requestedRangeNotSatisfiable) {
      await response.drain<void>();
      throw HttpException(
        'Failed to load audio (status: ${response.statusCode})',
        uri: uri,
      );
    }

    return AudioRangeResponse(
      statusCode: response.statusCode,
      contentLength: response.contentLength >= 0
          ? response.contentLength
          : null,
      contentRange: response.headers.value(HttpHeaders.contentRangeHeader),
      contentType: response.headers.contentType?.toString(),
      stream: cancellableHttpResponseStream(
        request: request,
        response: response,
        whenCancelled: cancellation.whenCancelled,
        isCancelled: () => cancellation.isCancelled,
        cancellationMessage: 'Audio transfer cancelled',
      ),
    );
  }

  Future<void> _abortRequestWhenReady(
    Future<HttpClientRequest> requestFuture,
  ) async {
    try {
      final request = await requestFuture;
      request.abort(const HttpException('Audio transfer cancelled'));
    } catch (_) {
      // The pending connection already failed, so there is nothing to abort.
    }
  }
}

typedef ExistingAudioFileResolver = Future<String?> Function(String hash);
typedef AudioCacheCompletedCallback = FutureOr<void> Function();
typedef AudioHeadersProvider = Map<String, String> Function();

/// Coordinates preload, playback ranges, and the contiguous audio cache prefix.
class AudioStreamCache {
  static const int _maxPlaybackCachePendingBytes = 1024 * 1024;

  AudioStreamCache({
    required AudioCacheFiles files,
    AudioRangeTransport? transport,
    ExistingAudioFileResolver? resolveExistingFile,
    AudioHeadersProvider? headersProvider,
    this.onCacheCompleted,
    void Function(String message)? logger,
  }) : _files = files,
       _transport = transport ?? HttpAudioRangeTransport(),
       _resolveExistingFile = resolveExistingFile ?? files.completedPath,
       _headersProvider = headersProvider ?? _emptyHeaders,
       _logger = logger ?? LogService.instance.captureOutput {
    _instances.add(this);
  }

  final AudioCacheFiles _files;
  final AudioRangeTransport _transport;
  final ExistingAudioFileResolver _resolveExistingFile;
  final AudioHeadersProvider _headersProvider;
  final AudioCacheCompletedCallback? onCacheCompleted;
  final void Function(String message) _logger;

  static final Set<AudioStreamCache> _instances = <AudioStreamCache>{};
  static final Map<String, int> _activePathCounts = <String, int>{};

  _PreloadOperation? _preload;
  final Map<String, _PlaybackWriteOperation> _playbackWriters = {};
  bool _disposed = false;

  static Map<String, String> _emptyHeaders() => const {};

  static bool isCachePathActive(String path) =>
      _activePathCounts.containsKey(p.normalize(path)) ||
      isCacheFileTransactionActive(path);

  static void markCachePathActive(String path) => _markPathActive(path);

  static void unmarkCachePathActive(String path) => _unmarkPathActive(path);

  static AudioCacheFileLease holdCacheFile(String path) {
    _markPathActive(path);
    return AudioCacheFileLease._(path, () => _unmarkPathActive(path));
  }

  static Future<void> cancelAllPreloads() async {
    await Future.wait(
      List<AudioStreamCache>.of(
        _instances,
      ).map((cache) => cache.setPreloadTarget(null)),
    );
  }

  Future<bool> setPreloadTarget(AudioTransferRequest? request) {
    if (_disposed) return Future.value(false);
    final current = _preload;
    if (request != null &&
        current != null &&
        current.request.hash == request.hash &&
        current.request.uri == request.uri &&
        !current.cancellation.isCancelled) {
      return current.future;
    }

    current?.requestCancel();
    if (request == null) {
      _preload = null;
      return current?.future.then((_) => false) ?? Future.value(false);
    }

    final operation = _PreloadOperation(request);
    _preload = operation;
    operation.future = _runPreloadAfter(current, operation);
    return operation.future;
  }

  Future<AudioPlaybackTarget> preparePlayback(
    AudioTransferRequest request,
  ) async {
    if (_disposed) throw StateError('AudioStreamCache is disposed');
    final preload = _preload;
    if (preload != null) {
      preload.requestCancel();
      await preload.future;
      if (identical(_preload, preload)) _preload = null;
    }
    await _cancelPlaybackWriter(request.hash);

    final completedPath = await _resolveCompletedPath(request.hash);
    if (completedPath != null) {
      return AudioFilePlaybackTarget(completedPath);
    }
    return AudioStreamPlaybackTarget(request);
  }

  Future<void> invalidate(String hash) async {
    final preload = _preload;
    if (preload?.request.hash == hash) {
      preload!.requestCancel();
      await preload.future;
      if (identical(_preload, preload)) _preload = null;
    }
    await _cancelPlaybackWriter(hash);
    await _files.invalidate(hash);
  }

  // Used only by CachingStreamAudioSource, which adapts this module to just_audio.
  Future<StreamAudioResponse> openRange(
    AudioTransferRequest request, [
    int? start,
    int? end,
  ]) async {
    if (_disposed) throw StateError('AudioStreamCache is disposed');
    final resolvedStart = start ?? 0;
    if (resolvedStart < 0 || (end != null && end < resolvedStart)) {
      throw RangeError('Invalid audio byte range: $resolvedStart-$end');
    }

    final preload = _preload;
    if (preload?.request.hash == request.hash) {
      preload!.requestCancel();
      await preload.future;
      if (identical(_preload, preload)) _preload = null;
    }
    await _cancelPlaybackWriter(request.hash);

    final completedPath = await _files.completedPath(request.hash);
    if (completedPath != null) {
      return _localFileResponse(
        File(completedPath),
        start: resolvedStart,
        end: end,
        sourceLength: await File(completedPath).length(),
      );
    }

    var partial = await _files.partialFile(request.hash, create: true);
    var prefixLength = await partial.length();
    var metadata = await _files.readPartialMetadata(request.hash);
    final knownLength = metadata?.sourceLength;
    if (knownLength != null && prefixLength > knownLength) {
      await _files.resetPartial(request.hash);
      partial = await _files.partialFile(request.hash, create: true);
      prefixLength = 0;
      metadata = null;
    }

    if (knownLength != null && prefixLength == knownLength) {
      final finalized = await _files.finalize(
        request.hash,
        expectedSize: knownLength,
      );
      if (finalized) {
        _notifyCacheCompleted();
        final completed = await _files.finalFile(request.hash);
        return _localFileResponse(
          completed,
          start: resolvedStart,
          end: end,
          sourceLength: knownLength,
          contentType: metadata?.contentType,
        );
      }
    }

    final localEnd = math.min(prefixLength, end ?? prefixLength);
    if (resolvedStart < prefixLength && end != null && end <= prefixLength) {
      return _localFileResponse(
        partial,
        start: resolvedStart,
        end: end,
        sourceLength: knownLength,
        contentType: metadata?.contentType,
      );
    }

    final remoteStart = resolvedStart < prefixLength
        ? prefixLength
        : resolvedStart;
    final cancellation = AudioTransferCancellation();
    final response = await _transport.open(
      uri: request.uri,
      start: remoteStart,
      end: end,
      headers: _headersProvider(),
      cancellation: cancellation,
    );
    late final _ResolvedAudioRange resolved;
    try {
      resolved = _resolveResponse(
        response,
        requestedStart: remoteStart,
        requestedEnd: end,
      );
    } on FormatException {
      cancellation.cancel();
      await _files.resetPartial(request.hash);
      rethrow;
    }

    if (resolved.rangeIgnored) {
      await _files.resetPartial(request.hash);
      partial = await _files.partialFile(request.hash, create: true);
      return _rangeIgnoredResponse(
        request: request,
        response: response,
        resolved: resolved,
        partial: partial,
        requestedStart: resolvedStart,
        requestedEnd: end,
        cancellation: cancellation,
      );
    }

    final shouldAppend = remoteStart == prefixLength;
    if (shouldAppend) {
      await _files.writePartialMetadata(
        request.hash,
        sourceLength: resolved.sourceLength,
        contentType: response.contentType,
      );
    }

    final localBytes = resolvedStart < localEnd ? localEnd - resolvedStart : 0;
    final combinedLength = resolved.responseLength == null
        ? (resolved.sourceLength == null
              ? null
              : resolved.sourceLength! - resolvedStart)
        : localBytes + resolved.responseLength!;

    if (!shouldAppend) {
      return StreamAudioResponse(
        sourceLength: resolved.sourceLength ?? knownLength,
        contentLength: combinedLength,
        offset: resolvedStart,
        stream: response.stream,
        contentType:
            response.contentType ??
            metadata?.contentType ??
            'application/octet-stream',
      );
    }

    final iterator = StreamIterator<List<int>>(response.stream);
    final writer = _PlaybackWriteOperation(cancellation, iterator);
    _playbackWriters[request.hash] = writer;
    return StreamAudioResponse(
      sourceLength: resolved.sourceLength ?? knownLength,
      contentLength: combinedLength,
      offset: resolvedStart,
      stream: _streamLocalThenAppend(
        request: request,
        partial: partial,
        localStart: resolvedStart,
        localEnd: localEnd,
        response: response,
        resolved: resolved,
        writer: writer,
      ),
      contentType:
          response.contentType ??
          metadata?.contentType ??
          'application/octet-stream',
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await setPreloadTarget(null);
    for (final hash in List<String>.of(_playbackWriters.keys)) {
      await _cancelPlaybackWriter(hash);
    }
    _disposed = true;
    _instances.remove(this);
  }

  Future<bool> _runPreloadAfter(
    _PreloadOperation? previous,
    _PreloadOperation operation,
  ) async {
    if (previous != null) await previous.future;
    if (_disposed ||
        operation.cancellation.isCancelled ||
        !identical(_preload, operation)) {
      return false;
    }
    final result = await _runPreload(operation);
    if (identical(_preload, operation)) _preload = null;
    return result;
  }

  Future<bool> _runPreload(_PreloadOperation operation) async {
    final request = operation.request;
    try {
      if (await _resolveCompletedPath(request.hash) != null) return true;

      var partial = await _files.partialFile(request.hash, create: true);
      var prefixLength = await partial.length();
      final metadata = await _files.readPartialMetadata(request.hash);
      if (metadata?.sourceLength != null &&
          prefixLength > metadata!.sourceLength!) {
        await _files.resetPartial(request.hash);
        partial = await _files.partialFile(request.hash, create: true);
        prefixLength = 0;
      }

      final response = await _transport.open(
        uri: request.uri,
        start: prefixLength,
        headers: _headersProvider(),
        cancellation: operation.cancellation,
      );
      late final _ResolvedAudioRange resolved;
      try {
        resolved = _resolveResponse(response, requestedStart: prefixLength);
      } on FormatException {
        await _files.resetPartial(request.hash);
        rethrow;
      }
      if (resolved.rangeIgnored) {
        await _files.resetPartial(request.hash);
        partial = await _files.partialFile(request.hash, create: true);
        prefixLength = 0;
      }

      await _files.writePartialMetadata(
        request.hash,
        sourceLength: resolved.sourceLength,
        contentType: response.contentType,
      );
      _markPathActive(partial.path);
      final iterator = StreamIterator<List<int>>(response.stream);
      operation.attach(iterator);
      RandomAccessFile? output;
      var received = 0;
      var completedResponse = false;
      try {
        output = await partial.open(mode: FileMode.writeOnlyAppend);
        while (!operation.cancellation.isCancelled &&
            await iterator.moveNext()) {
          final chunk = iterator.current;
          received += chunk.length;
          if (resolved.responseLength != null &&
              received > resolved.responseLength!) {
            throw const FormatException('Audio range exceeded declared length');
          }
          await output.writeFrom(chunk);
        }
        completedResponse = !operation.cancellation.isCancelled;
        await output.flush();
      } on FormatException {
        await output?.close();
        output = null;
        await _files.resetPartial(request.hash);
        rethrow;
      } finally {
        await output?.close();
        await iterator.cancel();
        _unmarkPathActive(partial.path);
      }

      if (!completedResponse ||
          (resolved.responseLength != null &&
              received != resolved.responseLength)) {
        return false;
      }

      final actualLength = await partial.length();
      final totalLength =
          resolved.sourceLength ??
          (response.statusCode == HttpStatus.ok ? actualLength : null);
      if (totalLength == null || actualLength != totalLength) return false;

      final finalized = await _files.finalize(
        request.hash,
        expectedSize: totalLength,
      );
      if (finalized) _notifyCacheCompleted();
      return finalized;
    } catch (error) {
      if (!operation.cancellation.isCancelled) {
        _logger('[AudioCache] 预加载失败: ${request.hash} - $error');
      }
      return false;
    }
  }

  Future<String?> _resolveCompletedPath(String hash) async {
    final external = await _resolveExistingFile(hash);
    if (external != null && await File(external).exists()) return external;
    return _files.completedPath(hash);
  }

  _ResolvedAudioRange _resolveResponse(
    AudioRangeResponse response, {
    required int requestedStart,
    int? requestedEnd,
  }) {
    final plan = resolveByteRangeResponse(
      statusCode: response.statusCode,
      requestedStart: requestedStart,
      requestedEndExclusive: requestedEnd,
      contentLength: response.contentLength,
      contentRange: response.contentRange,
      allowUnknownSourceLength: true,
    );
    return _ResolvedAudioRange(
      sourceLength: plan.sourceLength,
      responseLength: plan.responseLength,
      rangeIgnored:
          plan.kind == ByteRangeResponseKind.full &&
          (requestedStart != 0 || requestedEnd != null),
    );
  }

  StreamAudioResponse _localFileResponse(
    File file, {
    required int start,
    int? end,
    required int? sourceLength,
    String? contentType,
  }) {
    final length = sourceLength;
    final effectiveEnd = end == null
        ? (length ?? start)
        : (length == null ? end : math.min(end, length));
    if (effectiveEnd < start) {
      throw RangeError('Audio byte range starts beyond the cached file');
    }
    return StreamAudioResponse(
      sourceLength: length,
      contentLength: effectiveEnd - start,
      offset: start,
      stream: _readActiveFile(file, start, effectiveEnd),
      contentType: contentType ?? 'application/octet-stream',
    );
  }

  Stream<List<int>> _readActiveFile(File file, int start, int end) async* {
    _markPathActive(file.path);
    try {
      yield* file.openRead(start, end);
    } finally {
      _unmarkPathActive(file.path);
    }
  }

  StreamAudioResponse _rangeIgnoredResponse({
    required AudioTransferRequest request,
    required AudioRangeResponse response,
    required _ResolvedAudioRange resolved,
    required File partial,
    required int requestedStart,
    required int? requestedEnd,
    required AudioTransferCancellation cancellation,
  }) {
    final iterator = StreamIterator<List<int>>(response.stream);
    final writer = _PlaybackWriteOperation(cancellation, iterator);
    _playbackWriters[request.hash] = writer;
    final availableEnd = resolved.sourceLength;
    final effectiveEnd = requestedEnd == null || availableEnd == null
        ? requestedEnd ?? availableEnd
        : math.min(requestedEnd, availableEnd);
    final contentLength = effectiveEnd == null
        ? null
        : math.max(0, effectiveEnd - requestedStart);
    return StreamAudioResponse(
      sourceLength: resolved.sourceLength,
      contentLength: contentLength,
      offset: requestedStart,
      stream: _streamFullResponseForRange(
        request: request,
        partial: partial,
        response: response,
        resolved: resolved,
        requestedStart: requestedStart,
        requestedEnd: effectiveEnd,
        writer: writer,
      ),
      contentType: response.contentType ?? 'application/octet-stream',
    );
  }

  Stream<List<int>> _streamLocalThenAppend({
    required AudioTransferRequest request,
    required File partial,
    required int localStart,
    required int localEnd,
    required AudioRangeResponse response,
    required _ResolvedAudioRange resolved,
    required _PlaybackWriteOperation writer,
  }) async* {
    writer.started = true;
    _markPathActive(partial.path);
    _BufferedAudioCacheWriter? cacheWriter;
    var received = 0;
    var responseCompleted = false;
    var structurallyInvalid = false;
    var cacheWriteFailed = false;

    void reportCacheWriteFailure(Object error) {
      if (cacheWriteFailed) return;
      cacheWriteFailed = true;
      _logger('[AudioCache] Failed to write playback cache: $error');
    }

    Future<void> closeCacheWriter() async {
      final activeWriter = cacheWriter;
      if (activeWriter == null) return;
      cacheWriter = null;
      try {
        await activeWriter.close();
      } catch (error) {
        reportCacheWriteFailure(error);
      }
    }

    try {
      if (localEnd > localStart) {
        yield* partial.openRead(localStart, localEnd);
      }
      if (writer.cancellation.isCancelled) return;

      try {
        cacheWriter = _BufferedAudioCacheWriter(
          await partial.open(mode: FileMode.writeOnlyAppend),
          maxPendingBytes: _maxPlaybackCachePendingBytes,
        );
      } catch (error) {
        reportCacheWriteFailure(error);
      }
      while (!writer.cancellation.isCancelled &&
          await writer.iterator.moveNext()) {
        final chunk = writer.iterator.current;
        received += chunk.length;
        if (resolved.responseLength != null &&
            received > resolved.responseLength!) {
          structurallyInvalid = true;
          throw const FormatException('Audio range exceeded declared length');
        }

        Future<void>? cacheBackpressure;
        if (!cacheWriteFailed) {
          try {
            cacheBackpressure = cacheWriter?.enqueue(chunk);
          } catch (error) {
            reportCacheWriteFailure(error);
          }
        }
        yield chunk;
        if (cacheBackpressure != null) {
          try {
            await cacheBackpressure;
          } catch (error) {
            reportCacheWriteFailure(error);
          }
        }
      }
      responseCompleted = !writer.cancellation.isCancelled;
      await closeCacheWriter();
      if (responseCompleted &&
          resolved.responseLength != null &&
          received != resolved.responseLength) {
        throw const HttpException('Audio range ended before declared length');
      }
    } finally {
      await closeCacheWriter();
      await writer.iterator.cancel();
      _unmarkPathActive(partial.path);
      writer.complete();
      if (identical(_playbackWriters[request.hash], writer)) {
        _playbackWriters.remove(request.hash);
      }
      if (structurallyInvalid) {
        await _files.resetPartial(request.hash);
      } else if (responseCompleted && !cacheWriteFailed) {
        final completedLength =
            resolved.sourceLength ??
            (response.statusCode == HttpStatus.ok
                ? await partial.length()
                : null);
        await _finalizeIfComplete(request.hash, completedLength);
      }
    }
  }

  Stream<List<int>> _streamFullResponseForRange({
    required AudioTransferRequest request,
    required File partial,
    required AudioRangeResponse response,
    required _ResolvedAudioRange resolved,
    required int requestedStart,
    required int? requestedEnd,
    required _PlaybackWriteOperation writer,
  }) async* {
    writer.started = true;
    _markPathActive(partial.path);
    _BufferedAudioCacheWriter? cacheWriter;
    var cursor = 0;
    var responseCompleted = false;
    var structurallyInvalid = false;
    var cacheWriteFailed = false;

    void reportCacheWriteFailure(Object error) {
      if (cacheWriteFailed) return;
      cacheWriteFailed = true;
      _logger('[AudioCache] Failed to write playback cache: $error');
    }

    Future<void> closeCacheWriter() async {
      final activeWriter = cacheWriter;
      if (activeWriter == null) return;
      cacheWriter = null;
      try {
        await activeWriter.close();
      } catch (error) {
        reportCacheWriteFailure(error);
      }
    }

    try {
      await _files.writePartialMetadata(
        request.hash,
        sourceLength: resolved.sourceLength,
        contentType: response.contentType,
      );
      try {
        cacheWriter = _BufferedAudioCacheWriter(
          await partial.open(mode: FileMode.writeOnlyAppend),
          maxPendingBytes: _maxPlaybackCachePendingBytes,
        );
      } catch (error) {
        reportCacheWriteFailure(error);
      }
      while (!writer.cancellation.isCancelled &&
          await writer.iterator.moveNext()) {
        var chunk = writer.iterator.current;
        final limit = requestedEnd;
        if (limit != null && cursor + chunk.length > limit) {
          chunk = chunk.sublist(0, math.max(0, limit - cursor));
        }
        if (chunk.isEmpty) break;

        final chunkStart = cursor;
        final chunkEnd = cursor + chunk.length;
        if (resolved.sourceLength != null &&
            chunkEnd > resolved.sourceLength!) {
          structurallyInvalid = true;
          throw const FormatException('Audio response exceeded source length');
        }
        final yieldStart = math.max(chunkStart, requestedStart);
        final yieldEnd = limit == null ? chunkEnd : math.min(chunkEnd, limit);

        Future<void>? cacheBackpressure;
        if (!cacheWriteFailed) {
          try {
            cacheBackpressure = cacheWriter?.enqueue(chunk);
          } catch (error) {
            reportCacheWriteFailure(error);
          }
        }
        if (yieldEnd > yieldStart) {
          yield chunk.sublist(yieldStart - chunkStart, yieldEnd - chunkStart);
        }
        if (cacheBackpressure != null) {
          try {
            await cacheBackpressure;
          } catch (error) {
            reportCacheWriteFailure(error);
          }
        }
        cursor = chunkEnd;
        if (limit != null && cursor >= limit) break;
      }
      responseCompleted =
          !writer.cancellation.isCancelled &&
          (requestedEnd != null && cursor >= requestedEnd ||
              requestedEnd == null);
      await closeCacheWriter();
      if (requestedEnd == null &&
          resolved.responseLength != null &&
          cursor != resolved.responseLength) {
        throw const HttpException(
          'Audio response ended before declared length',
        );
      }
    } finally {
      await closeCacheWriter();
      await writer.iterator.cancel();
      _unmarkPathActive(partial.path);
      writer.complete();
      if (identical(_playbackWriters[request.hash], writer)) {
        _playbackWriters.remove(request.hash);
      }
      if (structurallyInvalid) {
        await _files.resetPartial(request.hash);
      } else if (responseCompleted && !cacheWriteFailed) {
        final completedLength =
            resolved.sourceLength ??
            (requestedEnd == null && response.statusCode == HttpStatus.ok
                ? await partial.length()
                : null);
        await _finalizeIfComplete(request.hash, completedLength);
      }
    }
  }

  Future<void> _finalizeIfComplete(String hash, int? sourceLength) async {
    if (sourceLength == null) return;
    final partial = await _files.partialFile(hash);
    if (!await partial.exists() || await partial.length() != sourceLength) {
      return;
    }
    if (await _files.finalize(hash, expectedSize: sourceLength)) {
      _notifyCacheCompleted();
    }
  }

  Future<void> _cancelPlaybackWriter(String hash) async {
    final writer = _playbackWriters.remove(hash);
    if (writer == null) return;
    await writer.cancel();
  }

  void _notifyCacheCompleted() {
    final callback = onCacheCompleted;
    if (callback == null) return;
    unawaited(
      Future<void>.sync(callback).catchError((Object error) {
        _logger('[AudioCache] 缓存维护失败: $error');
      }),
    );
  }

  static void _markPathActive(String path) {
    final normalized = p.normalize(path);
    _activePathCounts.update(
      normalized,
      (value) => value + 1,
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
}

class _ResolvedAudioRange {
  const _ResolvedAudioRange({
    required this.sourceLength,
    required this.responseLength,
    required this.rangeIgnored,
  });

  final int? sourceLength;
  final int? responseLength;
  final bool rangeIgnored;
}

class _PreloadOperation {
  _PreloadOperation(this.request);

  final AudioTransferRequest request;
  final AudioTransferCancellation cancellation = AudioTransferCancellation();
  late Future<bool> future;
  StreamIterator<List<int>>? iterator;

  void attach(StreamIterator<List<int>> value) {
    iterator = value;
    if (cancellation.isCancelled) unawaited(value.cancel());
  }

  void requestCancel() {
    cancellation.cancel();
    final activeIterator = iterator;
    if (activeIterator != null) unawaited(activeIterator.cancel());
  }
}

class _PlaybackWriteOperation {
  _PlaybackWriteOperation(this.cancellation, this.iterator);

  final AudioTransferCancellation cancellation;
  final StreamIterator<List<int>> iterator;
  final Completer<void> _done = Completer<void>();
  bool started = false;

  void complete() {
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> cancel() async {
    cancellation.cancel();
    await iterator.cancel();
    if (!started) complete();
    await _done.future;
  }
}

class _BufferedAudioCacheWriter {
  _BufferedAudioCacheWriter(this._file, {required this.maxPendingBytes});

  final RandomAccessFile _file;
  final int maxPendingBytes;
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  Completer<void>? _pendingBytesChanged;
  Object? _error;
  StackTrace? _errorStackTrace;
  int _pendingBytes = 0;
  bool _closed = false;

  Future<void>? enqueue(List<int> bytes) {
    if (_closed) throw StateError('Audio cache writer is closed');
    _throwIfFailed();

    _pendingBytes += bytes.length;
    _tail = _tail.then((_) async {
      try {
        if (_error == null) await _file.writeFrom(bytes);
      } catch (error, stackTrace) {
        _error ??= error;
        _errorStackTrace ??= stackTrace;
      } finally {
        _pendingBytes -= bytes.length;
        final changed = _pendingBytesChanged;
        _pendingBytesChanged = null;
        if (changed != null && !changed.isCompleted) changed.complete();
      }
    });

    return _pendingBytes > maxPendingBytes ? _waitForCapacity() : null;
  }

  Future<void> _waitForCapacity() async {
    while (_pendingBytes > maxPendingBytes && _error == null) {
      final changed = _pendingBytesChanged ??= Completer<void>();
      await changed.future;
    }
    _throwIfFailed();
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    await _tail;
    if (_error == null) {
      try {
        await _file.flush();
      } catch (error, stackTrace) {
        _error = error;
        _errorStackTrace = stackTrace;
      }
    }
    try {
      await _file.close();
    } catch (error, stackTrace) {
      _error ??= error;
      _errorStackTrace ??= stackTrace;
    }
    _throwIfFailed();
  }

  void _throwIfFailed() {
    final error = _error;
    if (error == null) return;
    Error.throwWithStackTrace(error, _errorStackTrace ?? StackTrace.current);
  }
}

import 'dart:io';

// ignore_for_file: experimental_member_use
import 'package:just_audio/just_audio.dart';

import 'cache_service.dart';
import 'storage_service.dart';

class CachingStreamAudioSource extends StreamAudioSource {
  CachingStreamAudioSource({
    required this.uri,
    required this.hash,
    HttpClient? client,
  }) : _clientOverride = client;

  static final HttpClient _sharedClient = _createClient();

  final Uri uri;
  final String hash;
  final HttpClient? _clientOverride;

  static HttpClient _createClient() {
    return HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30);
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final resolvedStart = start ?? 0;
    final client = _clientOverride ?? _sharedClient;
    final request = await client.getUrl(uri);

    if (resolvedStart != 0 || end != null) {
      final endInclusive = end != null ? end - 1 : null;
      final rangeHeader = endInclusive != null
          ? 'bytes=$resolvedStart-$endInclusive'
          : 'bytes=$resolvedStart-';
      request.headers.set(HttpHeaders.rangeHeader, rangeHeader);
    }

    // 如果配置了服务器cookie，则添加Cookie字段
    final cookieHeaders = StorageService.serverCookieHeaders;
    if (cookieHeaders.containsKey('Cookie')) {
      request.headers.add(HttpHeaders.cookieHeader, cookieHeaders['Cookie']!);
    }

    final response = await request.close();

    if (response.statusCode >= 400) {
      await response.drain<void>();
      throw HttpException(
        'Failed to load audio (status: ${response.statusCode})',
        uri: uri,
      );
    }

    final totalLength = _parseSourceLength(response.headers, resolvedStart);
    final responseLength = response.contentLength >= 0
        ? response.contentLength
        : (totalLength != null ? totalLength - resolvedStart : null);
    final contentType = response.headers.contentType?.toString();

    final tempFile = await CacheService.prepareAudioCacheTempFile(hash);
    final existingLength = await tempFile.length();

    // 非顺序请求时，仅做透传，不写入缓存
    if (resolvedStart != existingLength) {
      return StreamAudioResponse(
        sourceLength: totalLength,
        contentLength: responseLength,
        offset: resolvedStart,
        stream: response,
        contentType: contentType ?? 'application/octet-stream',
      );
    }

    return StreamAudioResponse(
      sourceLength: totalLength,
      contentLength: responseLength,
      offset: resolvedStart,
      stream: _streamAndCache(
        response: response,
        tempFile: tempFile,
        totalLength: totalLength,
      ),
      contentType: contentType ?? 'application/octet-stream',
    );
  }

  /// An async generator propagates downstream cancellation to the HTTP
  /// response. Switching tracks therefore stops the abandoned transfer instead
  /// of leaving dozens of old streams competing with the requested track.
  Stream<List<int>> _streamAndCache({
    required HttpClientResponse response,
    required File tempFile,
    required int? totalLength,
  }) async* {
    final raf = await tempFile.open(mode: FileMode.writeOnlyAppend);
    var closed = false;
    try {
      await for (final chunk in response) {
        // Deliver audio before waiting for the cache write to finish.
        yield chunk;
        await raf.writeFrom(chunk);
      }
      await raf.flush();
      await raf.close();
      closed = true;
      if (totalLength != null) {
        final finalized = await CacheService.finalizeAudioCacheFile(
          hash,
          expectedSize: totalLength,
        );
        if (!finalized) await CacheService.resetAudioCachePartial(hash);
      }
    } catch (_) {
      if (!closed) {
        await raf.close();
        closed = true;
      }
      await CacheService.resetAudioCachePartial(hash);
      rethrow;
    } finally {
      if (!closed) await raf.close();
    }
  }

  int? _parseSourceLength(HttpHeaders headers, int start) {
    final contentRange = headers.value(HttpHeaders.contentRangeHeader);
    if (contentRange != null) {
      final match = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(contentRange);
      if (match != null) {
        return int.tryParse(match.group(1)!);
      }
    }

    final length = headers.contentLength;
    if (length != -1 && start == 0) {
      return length;
    }
    return null;
  }
}

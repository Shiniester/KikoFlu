import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'http_byte_range.dart';
import 'remote_asset_cache.dart';

typedef ResumableDownloadProgress =
    void Function(int receivedBytes, int? totalBytes);

class ResumableFileTransferResult {
  const ResumableFileTransferResult({required this.totalBytes});

  final int totalBytes;
}

class ResumableFileTransfer {
  ResumableFileTransfer({RemoteAssetTransport? transport})
    : _transport = transport ?? HttpRemoteAssetTransport();

  final RemoteAssetTransport _transport;

  Future<ResumableFileTransferResult> download({
    required Uri uri,
    required File partialFile,
    required RemoteAssetCancellation cancellation,
    Map<String, String> headers = const {},
    bool expectedAudio = false,
    ResumableDownloadProgress? onProgress,
  }) async {
    final prefixLength = await partialFile.exists()
        ? await partialFile.length()
        : 0;
    final requestHeaders = <String, String>{
      ...headers,
      'Accept-Encoding': 'identity',
      if (prefixLength > 0) 'Range': 'bytes=$prefixLength-',
    };
    final response = await _transport.open(
      RemoteAssetTransportRequest(
        uri: uri,
        headers: requestHeaders,
        cancellation: cancellation,
      ),
    );

    late final ByteRangeResponsePlan plan;
    try {
      plan = resolveByteRangeResponse(
        statusCode: response.statusCode,
        requestedStart: prefixLength,
        contentLength: response.contentLength,
        contentRange: response.header(HttpHeaders.contentRangeHeader),
      );
    } on FormatException {
      await response.stream.drain<void>();
      if (await partialFile.exists()) await partialFile.delete();
      rethrow;
    } on HttpException {
      // Server failures do not invalidate a previously verified prefix.
      await response.stream.drain<void>();
      rethrow;
    }
    final contentType = response
        .header(HttpHeaders.contentTypeHeader)
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (plan.kind == ByteRangeResponseKind.alreadyComplete) {
      await response.stream.drain<void>();
      return ResumableFileTransferResult(totalBytes: prefixLength);
    }
    if (expectedAudio && contentType == 'text/html') {
      await response.stream.drain<void>();
      throw const HttpException('Unexpected HTML download response');
    }

    final iterator = StreamIterator<List<int>>(response.stream);
    final initialChunks = <List<int>>[];
    var initialByteCount = 0;
    if (expectedAudio) {
      try {
        while (initialByteCount < 64 && await iterator.moveNext()) {
          if (cancellation.isCancelled) {
            throw const HttpException('File transfer cancelled');
          }
          final chunk = iterator.current;
          initialChunks.add(chunk);
          initialByteCount += chunk.length;
        }
      } catch (_) {
        await iterator.cancel();
        rethrow;
      }
      if (_looksLikeHtml(initialChunks)) {
        await iterator.cancel();
        throw const HttpException('Unexpected HTML download response');
      }
    }

    final append = plan.kind == ByteRangeResponseKind.partial;
    final retainedPrefix = append ? prefixLength : 0;
    late final RandomAccessFile output;
    try {
      await partialFile.parent.create(recursive: true);
      output = await partialFile.open(
        mode: append ? FileMode.writeOnlyAppend : FileMode.write,
      );
    } catch (_) {
      await iterator.cancel();
      rethrow;
    }
    var received = 0;
    var structurallyInvalid = false;

    Future<void> writeChunk(List<int> chunk) async {
      if (cancellation.isCancelled) {
        throw const HttpException('File transfer cancelled');
      }
      final nextReceived = received + chunk.length;
      if (plan.responseLength != null && nextReceived > plan.responseLength!) {
        structurallyInvalid = true;
        throw const FormatException('Byte range exceeded its declared length');
      }
      await output.writeFrom(chunk);
      received = nextReceived;
      onProgress?.call(retainedPrefix + received, plan.sourceLength);
    }

    try {
      for (final chunk in initialChunks) {
        await writeChunk(chunk);
      }
      while (await iterator.moveNext()) {
        await writeChunk(iterator.current);
      }
      await output.flush();
    } finally {
      await iterator.cancel();
      await output.close();
      if (structurallyInvalid && await partialFile.exists()) {
        await partialFile.delete();
      }
    }
    if (plan.responseLength != null && received != plan.responseLength) {
      throw const HttpException('File transfer ended before declared length');
    }
    final actualLength = await partialFile.length();
    final totalLength = plan.sourceLength ?? actualLength;
    if (actualLength != totalLength) {
      throw const HttpException('File transfer is incomplete');
    }
    return ResumableFileTransferResult(totalBytes: totalLength);
  }

  bool _looksLikeHtml(List<List<int>> chunks) {
    final prefix = <int>[];
    for (final chunk in chunks) {
      prefix.addAll(chunk);
      if (prefix.length >= 128) break;
    }
    final text = ascii
        .decode(prefix, allowInvalid: true)
        .trimLeft()
        .toLowerCase();
    return text.startsWith('<!doctype html') ||
        text.startsWith('<html') ||
        text.startsWith('<head') ||
        text.startsWith('<body');
  }
}

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
    if (plan.kind == ByteRangeResponseKind.alreadyComplete) {
      await response.stream.drain<void>();
      return ResumableFileTransferResult(totalBytes: prefixLength);
    }

    final append = plan.kind == ByteRangeResponseKind.partial;
    final retainedPrefix = append ? prefixLength : 0;
    await partialFile.parent.create(recursive: true);
    final output = await partialFile.open(
      mode: append ? FileMode.writeOnlyAppend : FileMode.write,
    );
    var received = 0;
    var structurallyInvalid = false;
    try {
      await for (final chunk in response.stream) {
        if (cancellation.isCancelled) {
          throw const HttpException('File transfer cancelled');
        }
        received += chunk.length;
        if (plan.responseLength != null && received > plan.responseLength!) {
          structurallyInvalid = true;
          throw const FormatException(
            'Byte range exceeded its declared length',
          );
        }
        await output.writeFrom(chunk);
        onProgress?.call(retainedPrefix + received, plan.sourceLength);
      }
      await output.flush();
    } finally {
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
}

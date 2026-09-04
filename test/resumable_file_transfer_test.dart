import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/remote_asset_cache.dart';
import 'package:kikoeru_flutter/src/services/resumable_file_transfer.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'kikoflu_resumable_file_transfer_test_',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('resumes a download after the existing contiguous prefix', () async {
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await partial.writeAsBytes(const [1, 2]);
    final transport = _TransferTransport(
      const RemoteAssetResponse(
        statusCode: HttpStatus.partialContent,
        contentLength: 3,
        headers: {'content-range': 'bytes 2-4/5'},
        stream: Stream.empty(),
      ),
      body: const [3, 4, 5],
    );
    final transfer = ResumableFileTransfer(transport: transport);

    final result = await transfer.download(
      uri: Uri.parse('https://example.com/track.mp3'),
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
    );

    expect(transport.request!.headers['Range'], 'bytes=2-');
    expect(transport.request!.headers['Accept-Encoding'], 'identity');
    expect(result.totalBytes, 5);
    expect(await partial.readAsBytes(), const [1, 2, 3, 4, 5]);
  });

  test('a server that ignores Range safely replaces the old prefix', () async {
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await partial.writeAsBytes(const [1, 2]);
    final transport = _TransferTransport(
      const RemoteAssetResponse(
        statusCode: HttpStatus.ok,
        contentLength: 4,
        headers: {},
        stream: Stream.empty(),
      ),
      body: const [9, 8, 7, 6],
    );

    final result = await ResumableFileTransfer(transport: transport).download(
      uri: Uri.parse('https://example.com/track.mp3'),
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
    );

    expect(result.totalBytes, 4);
    expect(await partial.readAsBytes(), const [9, 8, 7, 6]);
  });

  test('a temporary server failure retains the resumable prefix', () async {
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await partial.writeAsBytes(const [1, 2]);
    final transport = _TransferTransport(
      const RemoteAssetResponse(
        statusCode: HttpStatus.serviceUnavailable,
        contentLength: 0,
        headers: {},
        stream: Stream.empty(),
      ),
      body: const [],
    );

    await expectLater(
      ResumableFileTransfer(transport: transport).download(
        uri: Uri.parse('https://example.com/track.mp3'),
        partialFile: partial,
        cancellation: RemoteAssetCancellation(),
      ),
      throwsA(isA<HttpException>()),
    );

    expect(await partial.readAsBytes(), const [1, 2]);
  });
}

class _TransferTransport implements RemoteAssetTransport {
  _TransferTransport(this.response, {required this.body});

  final RemoteAssetResponse response;
  final List<int> body;
  RemoteAssetTransportRequest? request;

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest request) async {
    this.request = request;
    return RemoteAssetResponse(
      statusCode: response.statusCode,
      contentLength: response.contentLength,
      headers: response.headers,
      stream: Stream.value(body),
    );
  }
}

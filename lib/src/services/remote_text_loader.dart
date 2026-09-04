import 'dart:async';
import 'dart:io';

import '../utils/encoding_utils.dart';
import 'remote_asset_cache.dart';

class RemoteTextContent {
  const RemoteTextContent({
    required this.text,
    required this.encoding,
    required this.file,
  });

  final String text;
  final String encoding;
  final File file;
}

class RemoteTextLease {
  RemoteTextLease._(this.key, this._assetLease, Duration timeout) {
    content = _assetLease.file
        .then((file) async {
          final bytes = await file.readAsBytes();
          final (text, encoding) = EncodingUtils.decodeBytes(bytes);
          return RemoteTextContent(text: text, encoding: encoding, file: file);
        })
        .timeout(
          timeout,
          onTimeout: () async {
            await _assetLease.release();
            throw TimeoutException(
              'Remote text request exceeded ${timeout.inSeconds} seconds',
            );
          },
        );
  }

  final RemoteAssetKey key;
  final RemoteAssetLease _assetLease;
  late final Future<RemoteTextContent> content;

  Future<void> release() => _assetLease.release();
}

class RemoteTextLoader {
  const RemoteTextLoader(
    this._cache, {
    this.timeout = const Duration(seconds: 30),
  });

  final RemoteAssetCache _cache;
  final Duration timeout;

  RemoteTextLease acquire({
    required Uri uri,
    required RemoteAssetKey key,
    required Map<String, String> headers,
  }) {
    final lease = _cache.acquire(
      RemoteAssetRequest(
        uri: uri,
        key: key,
        fileExtension: 'subtitle',
        headers: headers,
        allowRange: false,
        maxAge: const Duration(days: 30),
      ),
    );
    return RemoteTextLease._(key, lease, timeout);
  }
}

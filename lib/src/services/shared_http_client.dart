import 'dart:io';

import '../utils/server_utils.dart';

/// Long-lived client shared by audio, images, subtitles, documents and manual
/// downloads so requests to the same origin can reuse TCP/TLS connections.
final HttpClient sharedMediaHttpClient = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..idleTimeout = const Duration(seconds: 30);

void applyMediaRequestHeaders(
  HttpClientRequest request,
  Uri uri,
  Map<String, String> supplied, {
  bool forceIdentityEncoding = false,
}) {
  for (final header in supplied.entries) {
    request.headers.set(header.key, header.value);
  }
  final normalizedNames = supplied.keys
      .map((name) => name.toLowerCase())
      .toSet();
  final official = ServerUtils.isOfficialServer(uri.host);
  if (!normalizedNames.contains(HttpHeaders.userAgentHeader)) {
    request.headers.set(
      HttpHeaders.userAgentHeader,
      official
          ? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                'AppleWebKit/537.36 (KHTML, like Gecko) '
                'Chrome/142.0.0.0 Safari/537.36'
          : 'KikoFlu',
    );
  }
  if (official && !normalizedNames.contains(HttpHeaders.refererHeader)) {
    request.headers.set(HttpHeaders.refererHeader, 'https://www.asmr.one/');
  }
  if (official && !normalizedNames.contains('origin')) {
    request.headers.set('origin', 'https://www.asmr.one');
  }
  if (forceIdentityEncoding) {
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  }
}

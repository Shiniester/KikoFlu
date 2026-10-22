import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/remote_asset_cache.dart';
import 'package:kikoeru_flutter/src/videos/missav_browser_media.dart';

void main() {
  test('streams response headers and binary chunks through the browser', () async {
    final browser = _BrowserMedia();
    final opened = browser.open();
    await browser.fetchStarted.future;
    final request = browser.requestDescriptor;
    expect(request['headers'], {'range': 'bytes=0-3', 'if-range': '"etag"'});
    expect(browser.fetchScript, contains("credentials:'omit', mode:'cors'"));
    expect(browser.fetchScript, contains("redirect:'follow'"));
    expect(browser.fetchScript, isNot(contains('secret-cookie')));
    expect(browser.fetchScript, isNot(contains('Authorization')));

    browser.reply('headers', {
      'status': 206,
      'url': 'https://cdn.surrit.com/video.mp4',
      'headers': {
        'content-type': 'video/mp4',
        'content-length': '4',
        'content-range': 'bytes 0-3/4',
      },
    });
    final response = await opened;
    expect(response.statusCode, 206);
    expect(response.contentLength, 4);
    expect(response.header('content-range'), 'bytes 0-3/4');

    final bytes = <int>[];
    final done = Completer<void>();
    response.stream.listen(
      bytes.addAll,
      onDone: done.complete,
      onError: done.completeError,
    );
    browser.reply('chunk', {
      'index': 0,
      'data': base64Encode([0, 1, 254, 255]),
    });
    await _until(() => bytes.isNotEmpty);
    await _until(() => browser.scripts.any((script) => script.contains('.acks.get(0)')));
    browser.reply('end', {});
    await done.future;
    expect(bytes, [0, 1, 254, 255]);
    browser.transport.close();
    await browser.transport.whenClosed;
  });

  test('browser chunks wait for a listener and resume after stream pause', () async {
    final browser = _BrowserMedia();
    final opened = browser.open();
    await browser.fetchStarted.future;
    browser.reply('headers', {
      'status': 200,
      'url': 'https://cdn.surrit.com/video.mp4',
      'headers': {'content-type': 'video/mp4'},
    });
    final response = await opened;
    browser.reply('chunk', {
      'index': 0,
      'data': base64Encode([1, 2, 3]),
    });
    await Future<void>.delayed(Duration.zero);
    expect(browser.scripts.any((script) => script.contains('.acks.get(0)')), isFalse);

    final received = Completer<void>();
    final done = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = response.stream.listen((_) {
      if (!received.isCompleted) {
        received.complete();
        subscription.pause();
      }
    }, onDone: done.complete);
    await received.future;
    await Future<void>.delayed(Duration.zero);
    expect(browser.scripts.any((script) => script.contains('.acks.get(0)')), isFalse);

    subscription.resume();
    await _until(() => browser.scripts.any((script) => script.contains('.acks.get(0)')));
    browser.reply('end', {});
    await done.future;
    browser.transport.close();
    await browser.transport.whenClosed;
  });

  test('unlistened body stays bounded until cancellation', () async {
    final browser = _BrowserMedia();
    final cancellation = RemoteAssetCancellation();
    final opened = browser.open(cancellation: cancellation);
    await browser.fetchStarted.future;
    browser.reply('headers', {
      'status': 200,
      'url': 'https://cdn.surrit.com/video.mp4',
      'headers': {'content-type': 'video/mp4'},
    });
    final response = await opened;
    browser.reply('chunk', {
      'index': 0,
      'data': base64Encode(List<int>.filled(64 * 1024, 7)),
    });
    await Future<void>.delayed(Duration.zero);
    expect(browser.scripts.any((script) => script.contains('.acks.get(0)')), isFalse);

    final streamError = Completer<Object>();
    final streamDone = Completer<void>();
    response.stream.listen(
      (_) {},
      onError: streamError.complete,
      onDone: streamDone.complete,
    );
    cancellation.cancel();
    expect(await streamError.future, isA<Exception>());
    await streamDone.future;
    browser.transport.close();
    await browser.transport.whenClosed;
  });

  test('cancellation while checking the page prevents browser fetch setup', () async {
    final browser = _BrowserMedia()..currentUrlResult = Completer<String?>().future;
    final cancellation = RemoteAssetCancellation();
    final opened = browser.open(cancellation: cancellation);
    cancellation.cancel();
    await expectLater(opened, throwsA(isA<Exception>()));
    expect(browser.fetchScript, isEmpty);
    browser.transport.close();
    await browser.transport.whenClosed;
  });

  test('rejects private targets and non-MissAV browser pages', () async {
    for (final url in [
      'http://cdn.surrit.com/video.mp4',
      'https://user@cdn.surrit.com/video.mp4',
      'https://cdn.surrit.com:444/video.mp4',
      'https://127.0.0.1/video.mp4',
      'https://[::1]/video.mp4',
      'https://media.local/video.mp4',
      'https://media.internal/video.mp4',
    ]) {
      final browser = _BrowserMedia();
      await expectLater(
        browser.open(uri: Uri.parse(url)),
        throwsA(isA<Exception>()),
        reason: url,
      );
      expect(browser.fetchScript, isEmpty, reason: url);
      browser.transport.close();
      await browser.transport.whenClosed;
    }

    final browser = _BrowserMedia()..pageUrl = 'https://other.example/page';
    await expectLater(browser.open(), throwsA(isA<Exception>()));
    expect(browser.fetchScript, isEmpty);
    browser.transport.close();
    await browser.transport.whenClosed;
  });

  test('ignores messages with the wrong origin or browser nonce', () async {
    final browser = _BrowserMedia();
    final opened = browser.open();
    await browser.fetchStarted.future;
    final descriptor = browser.requestDescriptor;
    final valid = {
      'id': descriptor['id'],
      'nonce': descriptor['nonce'],
      'origin': 'https://missav.ai',
      'type': 'headers',
      'status': 200,
      'url': 'https://cdn.surrit.com/video.mp4',
      'headers': <String, String>{},
    };
    browser.transport.receiveMessage(valid, origin: 'https://wrong.example');
    browser.transport.receiveMessage(
      {...valid, 'nonce': 'different-session'},
      origin: 'https://missav.ai',
    );
    browser.transport.receiveMessage(valid, origin: 'https://missav.ai');
    final response = await opened;
    browser.reply('end', {});
    await response.stream.drain<void>();
    browser.transport.close();
    await browser.transport.whenClosed;
  });

  test('rejects redirects to private response hosts', () async {
    final browser = _BrowserMedia();
    final opened = browser.open();
    await browser.fetchStarted.future;
    browser.reply('headers', {
      'status': 200,
      'url': 'https://10.0.0.1/video.mp4',
      'headers': <String, String>{},
    });
    await expectLater(opened, throwsA(isA<Exception>()));
    browser.transport.close();
    await browser.transport.whenClosed;
  });

  test('close finishes a request waiting for response headers', () async {
    final browser = _BrowserMedia();
    final opened = browser.open();
    await browser.fetchStarted.future;
    browser.transport.close();
    await expectLater(opened, throwsA(isA<StateError>()));
    await browser.transport.whenClosed;
    expect(browser.disposeCalls, 1);
  });
}

class _BrowserMedia {
  _BrowserMedia() {
    transport = MissavBrowserMediaTransport(
      runJavaScript: (script) async {
        scripts.add(script);
        if (script.contains('const request = ')) {
          fetchScript = script;
          if (!fetchStarted.isCompleted) fetchStarted.complete();
        }
      },
      currentUrl: () => currentUrlResult ?? Future<String?>.value(pageUrl),
      disposeBrowser: () async {
        disposeCalls++;
      },
    );
  }

  late final MissavBrowserMediaTransport transport;
  final scripts = <String>[];
  final fetchStarted = Completer<void>();
  String pageUrl = 'https://missav.ai/cn';
  Future<String?>? currentUrlResult;
  String fetchScript = '';
  int disposeCalls = 0;

  Map<String, dynamic> get requestDescriptor {
    final match = RegExp(
      r'const request = (\{.*?\});',
      dotAll: true,
    ).firstMatch(fetchScript);
    if (match == null) throw StateError('Media request script was not sent.');
    return jsonDecode(match.group(1)!) as Map<String, dynamic>;
  }

  Future<RemoteAssetResponse> open({
    Uri? uri,
    RemoteAssetCancellation? cancellation,
  }) => transport.open(
    RemoteAssetTransportRequest(
      uri: uri ?? Uri.parse('https://cdn.surrit.com/video.mp4'),
      headers: {
        'Range': 'bytes=0-3',
        'if-range': '"etag"',
        'Cookie': 'secret-cookie',
        'Authorization': 'secret-auth',
        'User-Agent': 'secret-agent',
        'Origin': 'https://native.invalid',
        'Referer': 'https://native.invalid/',
      },
      cancellation: cancellation ?? RemoteAssetCancellation(),
    ),
  );

  void reply(String type, Map<String, Object?> fields) {
    final descriptor = requestDescriptor;
    transport.receiveMessage({
      ...fields,
      'id': descriptor['id'],
      'nonce': descriptor['nonce'],
      'origin': 'https://missav.ai',
      'type': type,
    }, origin: 'https://missav.ai');
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Expected browser media state was not reached.');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/videos/missav_browser_adapter.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

void main() {
  test(
    'browser owns credentials while JSON and source headers survive',
    () async {
      final browser = _Browser();
      final adapter = browser.adapter;
      browser.onRequest = (request) {
        expect(request['headers'], {
          'accept': 'application/json',
          'content-type': 'application/json',
        });
        expect(request['body'], '{"password":"value=="}');
        expect(
          browser.script,
          contains("credentials:'same-origin', mode:'same-origin'"),
        );
        browser.reply(request, body: '{"ok":true}');
      };
      final result = await adapter.fetch(
        _options(
          method: 'POST',
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Cookie': 'session=private',
            'User-Agent': 'native',
            'Authorization': 'private',
          },
        ),
        Stream.value(Uint8List.fromList(utf8.encode('{"password":"value=="}'))),
        null,
      );
      expect(result.statusCode, 200);
      expect(await utf8.decodeStream(result.stream), '{"ok":true}');
      adapter.close();
      await adapter.whenClosed;
    },
  );

  test(
    'rejects foreign origins and credentials before running browser code',
    () async {
      for (final uri in [
        'https://media.example.com/video',
        'https://jable.tv/',
        'http://missav.ai/cn',
        'https://user@missav.ai/cn',
        'https://missav.ai:444/cn',
      ]) {
        final browser = _Browser();
        await expectLater(
          browser.adapter.fetch(RequestOptions(path: uri), null, null),
          throwsA(isA<MissavUnsupportedException>()),
        );
        await expectLater(
          browser.adapter.loadDocument(Uri.parse(uri)),
          throwsA(isA<MissavUnsupportedException>()),
        );
        expect(browser.requests, isEmpty);
        expect(browser.navigations, isEmpty);
        browser.adapter.close();
      }
    },
  );

  test(
    'ignores messages from another origin or another browser session',
    () async {
      final browser = _Browser();
      browser.onRequest = (request) {
        browser.reply(
          request,
          origin: 'https://other.example',
          body: 'wrong origin',
        );
        browser.reply({...request, 'nonce': 'wrong'}, body: 'wrong session');
        browser.reply(
          request,
          payloadOrigin: 'https://other.example',
          body: 'wrong frame',
        );
        browser.reply(request, body: 'source response');
      };
      final result = await browser.adapter.fetch(_options(), null, null);
      expect(await utf8.decodeStream(result.stream), 'source response');
      browser.adapter.close();
    },
  );

  test('rejects a reported redirect outside the source', () async {
    final browser = _Browser();
    browser.onRequest = (request) =>
        browser.reply(request, url: 'https://other.example/');
    await expectLater(
      browser.adapter.fetch(_options(), null, null),
      throwsA(isA<MissavUnsupportedException>()),
    );
    browser.adapter.close();
  });

  test(
    'cancellation completes even while the platform script call is pending',
    () async {
      final browser = _Browser();
      browser.scriptGate = Completer<void>();
      final cancel = Completer<void>();
      final pending = browser.adapter.fetch(_options(), null, cancel.future);
      await browser.requestSent.future;
      final check = expectLater(
        pending,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      cancel.complete();
      await check;
      expect(browser.aborts, 1);
      browser.scriptGate!.complete();
      browser.adapter.close();
    },
  );

  test('closing the browser ends pending requests and disposes once', () async {
    final browser = _Browser();
    final pending = browser.adapter.fetch(_options(), null, null);
    await browser.requestSent.future;
    final check = expectLater(
      pending,
      throwsA(isA<MissavVerificationRequiredException>()),
    );
    browser.adapter.close(force: true);
    browser.adapter.close(force: true);
    await check;
    await browser.adapter.whenClosed;
    expect(browser.disposals, 1);
    await expectLater(
      browser.adapter.fetch(_options(), null, null),
      throwsA(isA<MissavVerificationRequiredException>()),
    );
  });

  test('timeout aborts the browser fetch', () async {
    final browser = _Browser();
    final options = _options()
      ..receiveTimeout = const Duration(milliseconds: 20);
    await expectLater(
      browser.adapter.fetch(options, null, null),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
    expect(browser.aborts, 1);
    browser.adapter.close();
  });

  testWidgets('queued API request receives its full timeout', (tester) async {
    final browser = _Browser();
    final navigation = Completer<String>();
    browser.navigationGate = navigation;
    browser.onRequest = (request) => browser.reply(request, body: 'ready');
    final first = browser.adapter.loadDocument(
      Uri.parse('https://missav.ai/cn/playlists/slow'),
    );
    first.ignore();
    final outcome = Completer<Object>();
    try {
      await tester.pump();
      expect(browser.navigationStarted.isCompleted, isTrue);
      final options = _options()
        ..receiveTimeout = const Duration(milliseconds: 20);
      unawaited(
        browser.adapter
            .fetch(options, null, null)
            .then<void>(
              outcome.complete,
              onError: (Object error) => outcome.complete(error),
            ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(outcome.isCompleted, isFalse);

      navigation.complete('<html>source page</html>');
      await tester.pump();
      await tester.pump();
      expect(await first, '<html>source page</html>');
      expect(outcome.isCompleted, isTrue);
      final response = await outcome.future;
      expect(response, isA<ResponseBody>());
      expect(
        await utf8.decodeStream((response as ResponseBody).stream),
        'ready',
      );
    } finally {
      if (!navigation.isCompleted) navigation.complete('<html></html>');
      browser.adapter.close();
      await tester.pump();
    }
  });

  testWidgets('queued document receives its full timeout', (tester) async {
    final browser = _Browser();
    browser.onRequest = (_) {};
    final first = browser.adapter.fetch(
      _options()..receiveTimeout = const Duration(minutes: 2),
      null,
      null,
    );
    first.ignore();
    final outcome = Completer<Object>();
    try {
      await tester.pump();
      expect(browser.requestSent.isCompleted, isTrue);
      unawaited(
        browser.adapter
            .loadDocument(Uri.parse('https://missav.ai/cn/download'))
            .then<void>(
              outcome.complete,
              onError: (Object error) => outcome.complete(error),
            ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      expect(outcome.isCompleted, isFalse);

      browser.reply(browser.requests.single, body: 'ready');
      await tester.pump();
      await tester.pump();
      expect((await first).statusCode, 200);
      expect(outcome.isCompleted, isTrue);
      expect(await outcome.future, '<html>source page</html>');
      expect(browser.navigations, ['https://missav.ai/cn/download']);
    } finally {
      browser.adapter.close();
      await tester.pump();
    }
  });

  testWidgets('queued request times out if the browser stays busy', (
    tester,
  ) async {
    final browser = _Browser();
    browser.onRequest = (_) {};
    final first = browser.adapter.fetch(
      _options()..receiveTimeout = const Duration(minutes: 2),
      null,
      null,
    );
    first.ignore();
    final outcome = Completer<Object>();
    try {
      await tester.pump();
      expect(browser.requestSent.isCompleted, isTrue);
      unawaited(
        browser.adapter
            .fetch(
              _options()..receiveTimeout = const Duration(milliseconds: 20),
              null,
              null,
            )
            .then<void>(
              outcome.complete,
              onError: (Object error) => outcome.complete(error),
            ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      expect(outcome.isCompleted, isTrue);
      expect(
        await outcome.future,
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      );
    } finally {
      browser.adapter.close();
      await tester.pump();
    }
  });

  testWidgets('a timed-out document releases the browser queue', (
    tester,
  ) async {
    final browser = _Browser()..navigationGate = Completer<String>();
    final outcome = Completer<Object>();
    unawaited(
      browser.adapter
          .loadDocument(Uri.parse('https://missav.ai/cn/playlists/slow'))
          .then<void>(
            outcome.complete,
            onError: (Object error) => outcome.complete(error),
          ),
    );
    try {
      await tester.pump();
      expect(browser.navigationStarted.isCompleted, isTrue);
      await tester.pump(const Duration(seconds: 31));
      expect(outcome.isCompleted, isTrue);
      expect(
        await outcome.future,
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      );
      expect(browser.navigationCancelled.isCompleted, isTrue);

      browser.navigationGate = null;
      final next = browser.adapter.loadDocument(
        Uri.parse('https://missav.ai/cn/download'),
      );
      await tester.pump();
      expect(await next, '<html>source page</html>');
    } finally {
      browser.adapter.close();
      await tester.pump();
    }
  });

  test(
    'an unfinished fetch holds the shared browser before navigation',
    () async {
      final browser = _Browser();
      browser.onRequest = (_) {};
      final fetch = browser.adapter.fetch(_options(), null, null);
      await browser.requestSent.future;
      final document = browser.adapter.loadDocument(
        Uri.parse('https://missav.ai/cn/open-604'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(browser.navigations, isEmpty);

      browser.reply(browser.requests.single, body: 'API response');
      final response = await fetch;
      expect(await utf8.decodeStream(response.stream), 'API response');
      expect(await document, '<html>source page</html>');
      expect(browser.navigations, ['https://missav.ai/cn/open-604']);
      browser.adapter.close();
    },
  );

  test('a cancelled queued document never navigates', () async {
    final browser = _Browser();
    browser.onRequest = (_) {};
    final fetch = browser.adapter.fetch(_options(), null, null);
    await browser.requestSent.future;
    final token = CancelToken();
    final document = browser.adapter.loadDocument(
      Uri.parse('https://missav.ai/cn/open-604'),
      cancelToken: token,
    );
    token.cancel();
    await expectLater(
      document,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    browser.reply(browser.requests.single, body: 'API response');
    await fetch;
    await Future<void>.delayed(Duration.zero);
    expect(browser.navigations, isEmpty);
    browser.adapter.close();
  });

  test(
    'API requests continue through fetch after a document navigation',
    () async {
      final browser = _Browser();
      expect(
        await browser.adapter.loadDocument(
          Uri.parse('https://missav.ai/cn/open-604'),
        ),
        '<html>source page</html>',
      );
      browser.onRequest = (request) =>
          browser.reply(request, body: '{"saved":true}');
      final response = await browser.adapter.fetch(
        RequestOptions(path: 'https://missav.ai/api/items/id/view'),
        null,
        null,
      );
      expect(await utf8.decodeStream(response.stream), '{"saved":true}');
      expect(browser.navigations, ['https://missav.ai/cn/open-604']);
      expect(
        browser.requests.single['url'],
        'https://missav.ai/api/items/id/view',
      );
      browser.adapter.close();
    },
  );

  test('cancelling an active document releases the queue', () async {
    final browser = _Browser()..navigationGate = Completer<String>();
    final token = CancelToken();
    final document = browser.adapter.loadDocument(
      Uri.parse('https://missav.ai/cn/open-604'),
      cancelToken: token,
    );
    await browser.navigationStarted.future;
    browser.navigationGate = null;
    token.cancel();
    final nextDocument = browser.adapter.loadDocument(
      Uri.parse('https://missav.ai/cn/playlists/next'),
    );
    await expectLater(
      document,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await browser.navigationCancelled.future;
    expect(await nextDocument, '<html>source page</html>');
    browser.onRequest = (request) =>
        browser.reply(request, body: 'API response');
    final response = await browser.adapter.fetch(
      RequestOptions(path: 'https://missav.ai/api/history'),
      null,
      null,
    );
    expect(await utf8.decodeStream(response.stream), 'API response');
    expect(browser.navigations, [
      'https://missav.ai/cn/open-604',
      'https://missav.ai/cn/playlists/next',
    ]);
    browser.adapter.close();
  });

  test('closing the adapter notifies an active document navigation', () async {
    final browser = _Browser()..navigationGate = Completer<String>();
    final pending = browser.adapter.loadDocument(
      Uri.parse('https://missav.ai/cn/open-604'),
    );
    await browser.navigationStarted.future;
    browser.adapter.close(force: true);
    await expectLater(
      pending,
      throwsA(isA<MissavVerificationRequiredException>()),
    );
    await browser.navigationCancelled.future;
    await browser.adapter.whenClosed;
    expect(browser.navigations, ['https://missav.ai/cn/open-604']);
  });

  test(
    'close while reading the browser URL prevents a later request',
    () async {
      final browser = _Browser()..urlGate = Completer<String?>();
      final pending = browser.adapter.fetch(_options(), null, null);
      final outcome = pending.then<Object?>(
        (_) => 'sent',
        onError: (Object error) => error,
      );
      await browser.urlRequested.future;
      browser.adapter.close();
      try {
        expect(
          await outcome.timeout(
            const Duration(milliseconds: 50),
            onTimeout: () => null,
          ),
          isA<MissavVerificationRequiredException>(),
        );
      } finally {
        browser.urlGate!.complete('https://missav.ai/cn');
        await outcome;
      }
      expect(browser.requests, isEmpty);
    },
  );

  test('cancel while reading a request body prevents a later POST', () async {
    final browser = _Browser();
    final bodyStarted = Completer<void>();
    final body = StreamController<Uint8List>(onListen: bodyStarted.complete);
    final cancel = Completer<void>();
    final pending = browser.adapter.fetch(
      _options(method: 'POST'),
      body.stream,
      cancel.future,
    );
    final outcome = pending.then<Object?>(
      (_) => 'sent',
      onError: (Object error) => error,
    );
    await bodyStarted.future;
    cancel.complete();
    try {
      expect(
        await outcome.timeout(
          const Duration(milliseconds: 50),
          onTimeout: () => null,
        ),
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      );
    } finally {
      await body.close();
      await outcome;
      browser.adapter.close();
    }
    expect(browser.requests, isEmpty);
  });
}

RequestOptions _options({
  String method = 'GET',
  Map<String, dynamic>? headers,
}) => RequestOptions(
  path: 'https://missav.ai/cn',
  method: method,
  headers: headers,
  receiveTimeout: const Duration(seconds: 2),
);

class _Browser {
  _Browser() {
    adapter = MissavBrowserAdapter(
      runJavaScript: (value) async {
        script = value;
        final match = RegExp(r'const request = (.*);').firstMatch(value);
        if (match == null) {
          aborts++;
          return;
        }
        final request = jsonDecode(match.group(1)!) as Map<String, dynamic>;
        requests.add(request);
        if (!requestSent.isCompleted) requestSent.complete();
        onRequest?.call(request);
        await scriptGate?.future;
      },
      currentUrl: () async {
        if (!urlRequested.isCompleted) urlRequested.complete();
        return await urlGate?.future ?? 'https://missav.ai/cn';
      },
      navigateDocument: (uri, cancelled) async {
        navigations.add(uri.toString());
        if (!navigationStarted.isCompleted) navigationStarted.complete();
        final stopped = cancelled.then<String>((_) {
          if (!navigationCancelled.isCompleted) navigationCancelled.complete();
          throw StateError('Navigation stopped.');
        });
        return await Future.any<String>([
          navigationGate?.future ?? Future.value('<html>source page</html>'),
          stopped,
        ]);
      },
      disposeBrowser: () async {
        disposals++;
      },
    );
  }

  late final MissavBrowserAdapter adapter;
  final requestSent = Completer<void>();
  final urlRequested = Completer<void>();
  final navigationStarted = Completer<void>();
  final navigationCancelled = Completer<void>();
  Completer<String?>? urlGate;
  Completer<String>? navigationGate;
  final requests = <Map<String, dynamic>>[];
  final navigations = <String>[];
  void Function(Map<String, dynamic>)? onRequest;
  Completer<void>? scriptGate;
  String script = '';
  int aborts = 0;
  int disposals = 0;

  void reply(
    Map<String, dynamic> request, {
    String body = 'ok',
    String origin = 'https://missav.ai',
    String payloadOrigin = 'https://missav.ai',
    String url = 'https://missav.ai/cn',
  }) {
    adapter.receiveMessage({
      'id': request['id'],
      'nonce': request['nonce'],
      'origin': payloadOrigin,
      'status': 200,
      'url': url,
      'headers': <String, String>{},
      'body': body,
    }, origin: origin);
  }
}

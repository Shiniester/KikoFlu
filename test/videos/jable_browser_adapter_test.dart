import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/videos/missav_browser_adapter.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

void main() {
  test('Jable browser rejects other sources before issuing requests', () async {
    var requests = 0;
    final adapter = MissavBrowserAdapter.jable(
      runJavaScript: (_) async {
        requests++;
      },
      currentUrl: () async => 'https://jable.tv/',
      navigateDocument: (_, _) async {
        requests++;
        return '<html></html>';
      },
      disposeBrowser: () async {},
    );
    addTearDown(() async {
      adapter.close();
      await adapter.whenClosed;
    });

    for (final url in [
      'https://missav.ai/cn',
      'https://jable.tv.example.com/',
      'http://jable.tv/',
      'https://user@jable.tv/',
      'https://jable.tv:444/',
    ]) {
      final rejected = throwsA(
        isA<VideoSourceException>().having(
          (error) => error.sourceKey,
          'sourceKey',
          'jable',
        ),
      );
      await expectLater(
        adapter.fetch(RequestOptions(path: url), null, null),
        rejected,
      );
      await expectLater(adapter.loadDocument(Uri.parse(url)), rejected);
    }
    expect(requests, 0);
  });

  test('Jable browser only accepts its own session response', () async {
    late final MissavBrowserAdapter adapter;
    adapter = MissavBrowserAdapter.jable(
      currentUrl: () async => 'https://jable.tv/',
      navigateDocument: (_, _) async => '<html></html>',
      disposeBrowser: () async {},
      runJavaScript: (script) async {
        final request =
            jsonDecode(
                  RegExp(
                    r'const request = (.+);',
                  ).firstMatch(script)!.group(1)!,
                )
                as Map<String, dynamic>;
        expect(script, contains(MissavBrowserAdapter.jableChannelName));
        expect(request['headers'], {'accept': 'text/html'});
        final response = {
          'id': request['id'],
          'nonce': request['nonce'],
          'origin': 'https://jable.tv',
          'url': request['url'],
          'status': 200,
          'body': 'Jable response',
          'headers': <String, String>{},
        };
        adapter.receiveMessage({
          ...response,
          'origin': 'https://missav.ai',
          'body': 'wrong source',
        }, origin: 'https://missav.ai');
        adapter.receiveMessage({
          ...response,
          'nonce': 'another session',
          'body': 'wrong session',
        }, origin: 'https://jable.tv');
        adapter.receiveMessage(response, origin: 'https://jable.tv');
      },
    );
    addTearDown(() async {
      adapter.close();
      await adapter.whenClosed;
    });

    final response = await adapter.fetch(
      RequestOptions(
        path: 'https://jable.tv/latest-updates/',
        headers: {
          'Accept': 'text/html',
          'Cookie': 'private',
          'Authorization': 'private',
        },
      ),
      null,
      null,
    );
    expect(await utf8.decodeStream(response.stream), 'Jable response');
  });

  test(
    'closing Jable browser ends an in-flight document with its source',
    () async {
      final started = Completer<void>();
      final document = Completer<String>();
      var disposals = 0;
      final adapter = MissavBrowserAdapter.jable(
        runJavaScript: (_) async {},
        currentUrl: () async => 'https://jable.tv/',
        navigateDocument: (_, _) {
          started.complete();
          return document.future;
        },
        disposeBrowser: () async {
          disposals++;
        },
      );
      final pending = adapter.loadDocument(
        Uri.parse('https://jable.tv/videos/example/'),
      );
      await started.future;
      final rejected = expectLater(
        pending,
        throwsA(isA<JableVerificationRequiredException>()),
      );
      adapter.close();
      adapter.close();
      await rejected;
      document.complete('<html>late response</html>');
      await adapter.whenClosed;
      expect(disposals, 1);
    },
  );

  test('Jable browser requests require a Jable page', () async {
    var scripts = 0;
    final adapter = MissavBrowserAdapter.jable(
      runJavaScript: (_) async {
        scripts++;
      },
      currentUrl: () async => 'https://missav.ai/cn',
      navigateDocument: (_, _) async => '<html></html>',
      disposeBrowser: () async {},
    );
    addTearDown(() async {
      adapter.close();
      await adapter.whenClosed;
    });
    await expectLater(
      adapter.fetch(RequestOptions(path: 'https://jable.tv/'), null, null),
      throwsA(isA<JableVerificationRequiredException>()),
    );
    expect(scripts, 0);
  });
}

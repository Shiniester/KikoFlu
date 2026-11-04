import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:kikoeru_flutter/src/videos/jable_client.dart';
import 'package:kikoeru_flutter/src/videos/jable_verification.dart';
import 'package:kikoeru_flutter/src/videos/missav_browser_adapter.dart';

void main() {
  test(
    'closing the verification window after handoff keeps the source browser',
    () async {
      final storage = _MemorySecureStorage();
      final client = JableClient(secureStorage: storage);
      addTearDown(client.dispose);
      final lifetime = JableBrowserConnectionLifetime(client);
      await client.importVerifiedSession(
        cookieHeader: 'session=member',
        userAgent: 'Browser',
      );
      lifetime.sessionImported(client.sessionGeneration);

      lifetime.handoff();
      await lifetime.cancel();

      expect(lifetime.isHandedOff, isTrue);
      expect(lifetime.isCancelled, isFalse);
      expect(storage.session, contains('session=member'));
    },
  );

  test(
    'closing before successful verification discards the imported credentials',
    () async {
      final storage = _MemorySecureStorage();
      final client = JableClient(secureStorage: storage);
      addTearDown(client.dispose);
      final lifetime = JableBrowserConnectionLifetime(client);
      await client.importVerifiedSession(
        cookieHeader: 'session=partial',
        userAgent: 'Browser',
      );
      lifetime.sessionImported(client.sessionGeneration);

      await lifetime.cancel();

      expect(lifetime.isHandedOff, isFalse);
      expect(lifetime.isCancelled, isTrue);
      expect(storage.session, isNull);
    },
  );

  test('Android WebView document markup is decoded before HTML parsing', () {
    const markup = '''
      <html><body>
        <div class="video-img-box">Video</div>
        <script>var hlsUrl = "https://media.example/master.m3u8";</script>
      </body></html>
    ''';

    final decoded = jableDocumentMarkup(jsonEncode(markup), android: true);
    final document = html_parser.parse(decoded);

    expect(document.querySelector('.video-img-box'), isNotNull);
    expect(
      document.querySelector('script')!.text,
      contains('hlsUrl = "https://media.example/master.m3u8"'),
    );
  });

  test(
    'a stale browser failure does not detach a newly attached session',
    () async {
      final client = JableClient(secureStorage: _MemorySecureStorage());
      await client.initialize();
      final oldSessionGeneration = client.sessionGeneration;
      final oldNavigation = Completer<void>();
      final allowOldFailure = Completer<void>();
      final oldBrowser = MissavBrowserAdapter.jable(
        runJavaScript: (_) async {},
        currentUrl: () async => 'https://jable.tv/',
        navigateDocument: (_, __) async => '<html></html>',
        disposeBrowser: () async {},
      );
      var newBrowserNavigations = 0;
      final newBrowser = MissavBrowserAdapter.jable(
        runJavaScript: (_) async {},
        currentUrl: () async => 'https://jable.tv/',
        navigateDocument: (uri, _) async {
          newBrowserNavigations++;
          return '<html><head><title>New session</title></head></html>';
        },
        disposeBrowser: () async {},
      );

      final oldConnection = () async {
        oldNavigation.complete();
        await allowOldFailure.future;
        final detached = client.restoreNativeTransportIfCurrent(
          expectedAdapter: oldBrowser,
          expectedGeneration: oldSessionGeneration,
          connectionGeneration: 1,
        );
        oldBrowser.close(force: true);
        await oldBrowser.whenClosed;
        expect(detached, isFalse);
      }();
      await oldNavigation.future;
      await client.importVerifiedSession(
        cookieHeader: 'cf_clearance=verified',
        userAgent: 'Browser agent',
        expectedGeneration: oldSessionGeneration,
      );
      client.useVerifiedBrowserTransport(
        newBrowser,
        expectedGeneration: client.sessionGeneration,
        connectionGeneration: 2,
      );
      allowOldFailure.complete();
      await oldConnection;

      final page = await client.browse('https://jable.tv/');

      expect(page.title, 'New session');
      expect(newBrowserNavigations, 1);
      expect(newBrowser.isClosed, isFalse);
      client.dispose();
    },
  );
}

class _MemorySecureStorage implements FlutterSecureStorage {
  String? session;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) return Future<String?>.value(session);
    if (invocation.memberName == #write) {
      session = invocation.namedArguments[#value] as String?;
    }
    if (invocation.memberName == #delete) session = null;
    return Future<void>.value();
  }
}

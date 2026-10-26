import 'dart:async';
import 'dart:convert';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/missav_browser_adapter.dart';
import 'package:kikoeru_flutter/src/videos/missav_verification.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:webview_flutter/webview_flutter.dart';
// This mock extends the transitive platform API used by webview_flutter.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final loginStatus in [200, 401]) {
    test(
      'verified browser stays usable after login (status=$loginStatus)',
      () async {
        final oldPlatform = WebViewPlatform.instance;
        WebViewPlatform.instance = _FakeWebViewPlatform(Future.value(const []));
        addTearDown(() {
          if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
        });
        final controller = WebViewController();
        final client = MissavClient(secureStorage: _MemorySecureStorage());
        addTearDown(client.dispose);
        late final MissavBrowserAdapter adapter;
        late final int verifiedGeneration;
        void ensureCurrent() => ensureMissavBrowserConnectionCurrent(
          0,
          null,
          client: client,
          clientGeneration: verifiedGeneration,
          browserAdapter: adapter,
        );
        adapter = MissavBrowserAdapter(
          runJavaScript: (script) async {
            final match = RegExp(r'const request = (.*);').firstMatch(script)!;
            final request = jsonDecode(match.group(1)!) as Map;
            adapter.receiveMessage({
              'id': request['id'],
              'nonce': request['nonce'],
              'origin': MissavClient.origin,
              'status': loginStatus,
              'url': request['url'],
              'headers': {'content-type': 'application/json'},
              'body': loginStatus == 200 ? '{"user":{"name":"viewer"}}' : '{}',
            });
          },
          currentUrl: () => missavMobileSourceUrl(controller),
          navigateDocument: (uri, cancelled) => navigateMissavDocument(
            uri,
            cancelled,
            navigate: (signal) => waitForMissavMobilePage(
              controller,
              uri.toString(),
              cancelSignal: signal,
              ensureActive: () {},
            ),
            read: (_) async => {
              'url': uri.toString(),
              'html':
                  '<html><head><title>Catalog</title></head><body></body></html>',
            },
            stop: () => controller.runJavaScript('window.stop();'),
            releaseDocument: (_) => parkMissavMobileBrowser(
              controller,
              ensureActive: ensureCurrent,
            ),
          ),
          disposeBrowser: () async {},
        );
        await client.importVerifiedSession(
          cookieHeader: 'session=verified',
          userAgent: 'Test browser',
        );
        client.useVerifiedBrowserTransport(adapter);
        verifiedGeneration = client.sessionGeneration;
        expect((await client.browse(client.homeUrl)).url, client.homeUrl);

        final login = client.login(
          email: 'viewer@example.test',
          password: 'sample',
        );
        if (loginStatus == 200) {
          await login;
        } else {
          await expectLater(
            login,
            throwsA(isA<MissavAuthenticationException>()),
          );
        }
        expect(client.sessionGeneration, greaterThan(verifiedGeneration));
        expect(adapter.isClosed, isFalse);
        expect((await client.browse(client.homeUrl)).url, client.homeUrl);
        expect(await controller.currentUrl(), 'about:blank');

        expect(
          () => ensureMissavBrowserConnectionCurrent(
            0,
            null,
            client: client,
            clientGeneration: verifiedGeneration,
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          () => ensureMissavBrowserConnectionCurrent(
            -1,
            null,
            browserAdapter: adapter,
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          () => ensureMissavBrowserConnectionCurrent(
            0,
            Completer<void>()..complete(),
            browserAdapter: adapter,
          ),
          throwsA(isA<StateError>()),
        );
        client.restoreNativeTransport();
        expect(ensureCurrent, throwsA(isA<StateError>()));
      },
    );
  }

  test(
    'idle mobile bridge unloads the website without another network navigation',
    () async {
      final oldPlatform = WebViewPlatform.instance;
      final navigationFinished = Completer<void>();
      final platform = _FakeWebViewPlatform(
        Future.value(const []),
        onLoadHtml: () => navigationFinished.future,
      );
      WebViewPlatform.instance = platform;
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });
      final controller = WebViewController();
      final browser = controller.platform as _FakeWebViewController;
      var parked = false;
      final parking = parkMissavMobileBrowser(
        controller,
      ).then((_) => parked = true);
      addTearDown(() async {
        if (!navigationFinished.isCompleted) navigationFinished.complete();
        await parking;
      });
      await browser.htmlLoadStarted.future;
      expect(parked, isFalse);
      // A late finish event from the old website cannot release the bridge load.
      browser._navigationDelegate!.pageFinished!('https://missav.ai/cn');
      await Future<void>.delayed(Duration.zero);
      expect(parked, isFalse);
      navigationFinished.complete();
      await parking;
      expect(browser.networkNavigations, 0);
      expect(await controller.currentUrl(), 'about:blank');
      expect(await missavMobileSourceUrl(controller), 'https://missav.ai/');
      expect(browser.htmlDocument, isNot(contains('<script')));
    },
  );

  test(
    'mobile source gate rejects a foreign or opaque document origin',
    () async {
      final oldPlatform = WebViewPlatform.instance;
      WebViewPlatform.instance = _FakeWebViewPlatform(Future.value(const []));
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });
      final controller = WebViewController();
      final browser = controller.platform as _FakeWebViewController;
      for (final url in [
        'https://other.example/',
        'about:blank',
        'http://missav.ai/',
      ]) {
        browser.documentUrl = url;
        expect(await missavMobileSourceUrl(controller), isNull, reason: url);
      }
    },
  );

  test(
    'document requests release the source page before the next request',
    () async {
      final released = Completer<void>();
      final releaseStarted = Completer<void>();
      var sourcePageRetained = true;
      var secondNavigationStarted = false;
      late final MissavBrowserAdapter adapter;
      adapter = MissavBrowserAdapter(
        runJavaScript: (_) async {},
        currentUrl: () async => 'https://missav.ai/cn',
        navigateDocument: (uri, cancelled) => navigateMissavDocument(
          uri,
          cancelled,
          navigate: (_) async {
            if (releaseStarted.isCompleted) secondNavigationStarted = true;
          },
          read: (_) async => {
            'url': uri.toString(),
            'html': '<html>catalog</html>',
          },
          stop: () async {},
          releaseDocument: (_) async {
            if (!releaseStarted.isCompleted) releaseStarted.complete();
            await released.future;
            sourcePageRetained = false;
          },
        ),
        disposeBrowser: () async {},
      );
      addTearDown(() async {
        if (!released.isCompleted) released.complete();
        adapter.close();
        await adapter.whenClosed;
      });

      final first = adapter.loadDocument(Uri.parse('https://missav.ai/cn'));
      await Future<void>.delayed(Duration.zero);
      expect(releaseStarted.isCompleted, isTrue);
      var firstFinished = false;
      unawaited(first.then((_) => firstFinished = true));
      final second = adapter.loadDocument(
        Uri.parse('https://missav.ai/cn/new'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(firstFinished, isFalse);
      expect(secondNavigationStarted, isFalse);
      released.complete();
      expect(await first, '<html>catalog</html>');
      expect(await second, '<html>catalog</html>');
      expect(sourcePageRetained, isFalse);
      expect(secondNavigationStarted, isTrue);
    },
  );

  for (final cancel in [false, true]) {
    test(
      'failed hidden navigation stops before unloading (cancel=$cancel)',
      () async {
        final cancelled = Completer<void>();
        final started = Completer<void>();
        final stopStarted = Completer<void>();
        final stopFinished = Completer<void>();
        var stopped = false;
        var released = false;
        final document = navigateMissavDocument(
          Uri.parse('https://missav.ai/cn'),
          cancelled.future,
          navigate: (signal) async {
            started.complete();
            if (cancel) {
              await signal.future;
              throw StateError('cancelled');
            }
          },
          read: (_) async => throw const FormatException('invalid document'),
          stop: () async {
            stopStarted.complete();
            await stopFinished.future;
            stopped = true;
          },
          releaseDocument: (documentRead) async {
            expect(documentRead, isFalse);
            expect(stopped, isTrue);
            released = true;
          },
        );
        final outcome = expectLater(
          document,
          throwsA(cancel ? isA<StateError>() : isA<FormatException>()),
        );
        await started.future;
        if (cancel) cancelled.complete();
        await stopStarted.future;
        expect(released, isFalse);
        stopFinished.complete();
        await outcome;
        expect(released, isTrue);
      },
    );
  }

  test('late parking errors never stop a replacement page', () async {
    final cancelled = Completer<void>();
    final releaseStarted = Completer<void>();
    final releaseFinished = Completer<void>();
    var stops = 0;
    final document = navigateMissavDocument(
      Uri.parse('https://missav.ai/cn'),
      cancelled.future,
      navigate: (_) async {},
      read: (_) async => {
        'url': 'https://missav.ai/cn',
        'html': '<html></html>',
      },
      stop: () async => stops++,
      releaseDocument: (_) async {
        releaseStarted.complete();
        await releaseFinished.future;
        throw StateError('old browser closed');
      },
    );
    final outcome = expectLater(document, throwsA(isA<StateError>()));
    await releaseStarted.future;
    cancelled.complete();
    releaseFinished.complete();
    await outcome;
    expect(stops, 0);
  });

  test('replaced mobile sessions cannot load a late bridge document', () async {
    final oldPlatform = WebViewPlatform.instance;
    WebViewPlatform.instance = _FakeWebViewPlatform(Future.value(const []));
    addTearDown(() {
      if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
    });
    final controller = WebViewController();
    final browser = controller.platform as _FakeWebViewController;
    var checks = 0;
    await expectLater(
      parkMissavMobileBrowser(
        controller,
        ensureActive: () {
          if (++checks == 2) throw StateError('session replaced');
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(browser.htmlLoadStarted.isCompleted, isFalse);
    expect(browser.networkNavigations, 0);
  });

  test('Android accepts the verified browser document', () async {
    const html = '<html><a href="/logout">退出登录</a></html>';
    final document = jsonEncode({'url': 'https://missav.ai/cn', 'html': html});
    var stopped = false;

    final result = await navigateMissavDocument(
      Uri.parse('https://missav.ai/cn'),
      Completer<void>().future,
      navigate: (_) async {},
      // Android evaluateJavascript encodes string results as JSON strings.
      read: (_) async => jsonEncode(document),
      stop: () async => stopped = true,
    );

    expect(result, html);
    expect(stopped, isFalse);
  });

  test('accepts a document returned as JSON or a platform map', () async {
    const document = {
      'url': 'https://missav.ai/en',
      'html': '<html><a href="/logout">Log out</a></html>',
    };
    for (final result in [jsonEncode(document), document]) {
      expect(
        await navigateMissavDocument(
          Uri.parse('https://missav.ai/en'),
          Completer<void>().future,
          navigate: (_) async {},
          read: (_) async => result,
          stop: () async {},
        ),
        document['html'],
      );
    }
  });

  test(
    'does not treat an invalid browser document as a verification challenge',
    () async {
      final document = jsonEncode({
        'url': 'https://other.example/cn',
        'html': '<html>Not the source</html>',
      });
      for (final result in [document, jsonEncode(document)]) {
        var stopped = false;
        await expectLater(
          navigateMissavDocument(
            Uri.parse('https://missav.ai/cn'),
            Completer<void>().future,
            navigate: (_) async {},
            read: (_) async => result,
            stop: () async => stopped = true,
          ),
          throwsA(
            allOf(
              isA<MissavException>(),
              isNot(isA<MissavVerificationRequiredException>()),
            ),
          ),
        );
        expect(stopped, isTrue);
      }
    },
  );

  test(
    'desktop cancellation waits for the old navigation completion',
    () async {
      final browser = _DesktopBrowser();
      var finished = false;
      final stopped = stopMissavDesktopNavigation(browser).then((_) {
        finished = true;
      });
      await browser.stopRequested.future;
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);

      browser.state.value = const WebviewNavigationState(
        url: 'https://missav.ai/cn',
        isLoading: false,
      );
      await stopped;
      expect(finished, isTrue);
      browser.state.dispose();
    },
  );

  test('verification stays on the exact HTTPS source origin', () {
    expect(isMissavVerificationUrl('https://missav.ai/dm247/cn'), isTrue);
    expect(isMissavVerificationUrl('https://missav.ai:443/cn'), isTrue);
    for (final url in [
      'http://missav.ai/cn',
      'https://missav.ai:444/cn',
      'https://missav.ai.example.com/cn',
      'https://cdn.missav.ai/cn',
      'https://user@missav.ai/cn',
      'javascript:alert(1)',
      'about:blank',
      'not a URL',
    ]) {
      expect(isMissavVerificationUrl(url), isFalse, reason: url);
    }
  });

  test(
    'stale Android proxy cleanup cannot release a newer configuration',
    () async {
      const channel = MethodChannel('com.meteor.kikoeruflutter/missav_browser');
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final oldOwner = await configureMissavAndroidProxy();
      final newOwner = await configureMissavAndroidProxy();
      await releaseMissavAndroidProxy(oldOwner);

      expect(calls, ['configureProxy', 'configureProxy']);
      await releaseMissavAndroidProxy(newOwner);
      await releaseMissavAndroidProxy(newOwner);
      expect(calls, ['configureProxy', 'configureProxy', 'resetProxy']);
    },
  );

  test(
    'mobile navigation ignores old bridge and empty-document finishes',
    () async {
      for (final (hasRoot, rootId) in [
        (true, 'kikoflu-browser-bridge'),
        (false, null),
      ]) {
        final oldPlatform = WebViewPlatform.instance;
        final loadStarted = Completer<void>();
        final finishLoad = Completer<void>();
        final platform = _FakeWebViewPlatform(
          Completer<List<WebViewCookie>>().future,
          initialUrl: null,
          onLoadRequest: (_) async {
            loadStarted.complete();
            await finishLoad.future;
          },
        );
        WebViewPlatform.instance = platform;
        addTearDown(() {
          if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
        });

        final controller = WebViewController();
        final browser = controller.platform as _FakeWebViewController;
        browser.documentUrl = 'https://missav.ai/';
        browser.hasDocumentElement = hasRoot;
        browser.documentElementId = rootId;
        var finished = false;
        final navigation = waitForMissavMobilePage(
          controller,
          'https://missav.ai/cn',
          ensureActive: () {},
        ).then((_) => finished = true);
        await loadStarted.future;

        browser._navigationDelegate!.pageFinished!('https://missav.ai/');
        await browser.verificationReadyCheckStarted.future;
        await Future<void>.delayed(Duration.zero);
        expect(await controller.currentUrl(), isNull);
        expect(finished, isFalse);

        finishLoad.complete();
        await navigation;
        expect(await controller.currentUrl(), 'https://missav.ai/cn');
        expect(finished, isTrue);
      }
    },
  );

  test(
    'a missing document root fails the document read without markup access',
    () async {
      var stopped = false;
      var released = false;

      await expectLater(
        navigateMissavDocument(
          Uri.parse('https://missav.ai/cn'),
          Completer<void>().future,
          navigate: (_) async {},
          read: (script) async {
            expect(script, contains('if (!root) return null;'));
            return null;
          },
          stop: () async => stopped = true,
          releaseDocument: (documentRead) async {
            expect(documentRead, isFalse);
            released = true;
          },
        ),
        throwsA(isA<MissavException>()),
      );

      expect(stopped, isTrue);
      expect(released, isTrue);
    },
  );

  test('only live root cookies for the source enter the native session', () {
    final now = DateTime.now();
    final cookies = [
      _cookie(
        'clearance',
        domain: '.missav.ai',
        expires: now.add(const Duration(days: 1)),
      ),
      _cookie('session', httpOnly: true, sessionOnly: true),
      _cookie('expired', expires: now.subtract(const Duration(days: 1))),
      _cookie('other', domain: 'media.example.com'),
      _cookie('suffix', domain: 'missav.ai.example.com'),
      _cookie('subdomain', domain: 'cdn.missav.ai'),
      _cookie('path', path: '/account'),
    ];
    expect(
      missavVerificationCookieHeader(cookies),
      'clearance=value; session=value',
    );
  });

  test(
    'WebView2 terminating NUL does not discard or corrupt source cookies',
    () {
      expect(
        missavVerificationCookieHeader([
          WebviewCookie(
            name: 'session\u0000',
            value: 'value==\u0000',
            domain: '.missav.ai\u0000',
            path: '/\u0000',
            expires: null,
            secure: true,
            httpOnly: true,
            sessionOnly: true,
          ),
        ]),
        'session=value==',
      );
    },
  );

  test(
    'a cancelled cookie read cannot import a late browser session',
    () async {
      final oldPlatform = WebViewPlatform.instance;
      final cookies = Completer<List<WebViewCookie>>();
      final webViewPlatform = _FakeWebViewPlatform(cookies.future);
      WebViewPlatform.instance = webViewPlatform;
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });

      final storage = _MemorySecureStorage();
      final client = MissavClient(secureStorage: storage);
      addTearDown(client.dispose);
      await client.initialize();
      final initialGeneration = client.sessionGeneration;
      final cancellation = Completer<void>();
      final connection = connectMissavBrowserSession(
        client,
        mobile: WebViewController(),
        cancelSignal: cancellation,
      );

      await webViewPlatform.cookiesRequested.future.timeout(
        const Duration(seconds: 5),
      );
      cancellation.complete();
      await expectLater(connection, throwsA(isA<StateError>()));

      cookies.complete([
        const WebViewCookie(
          name: 'session',
          value: 'late',
          domain: 'missav.ai',
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(client.sessionGeneration, initialGeneration);
      expect(storage.writeCalls, 0);
    },
  );
}

class _DesktopBrowser extends Fake implements Webview {
  final state = ValueNotifier(
    const WebviewNavigationState(url: 'https://missav.ai/cn', isLoading: true),
  );
  final stopRequested = Completer<void>();
  final closed = Completer<void>();

  @override
  ValueListenable<WebviewNavigationState> get navigationState => state;

  @override
  Future<void> get onClose => closed.future;

  @override
  Future<void> stop() async => stopRequested.complete();
}

class _FakeWebViewPlatform extends WebViewPlatform {
  _FakeWebViewPlatform(
    this.cookies, {
    this.initialUrl = 'https://missav.ai/cn',
    this.onLoadRequest,
    this.onLoadHtml,
  });

  final Future<List<WebViewCookie>> cookies;
  final String? initialUrl;
  final Future<void> Function(LoadRequestParams params)? onLoadRequest;
  final Future<void> Function()? onLoadHtml;
  final cookiesRequested = Completer<void>();

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _FakeWebViewController(
    params,
    initialUrl: initialUrl,
    onLoadRequest: onLoadRequest,
    onLoadHtml: onLoadHtml,
  );

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakeNavigationDelegate(params);

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) => _FakeCookieManager(params, cookies, cookiesRequested);
}

class _FakeWebViewController extends PlatformWebViewController {
  _FakeWebViewController(
    super.params, {
    required String? initialUrl,
    this.onLoadRequest,
    this.onLoadHtml,
  }) : _url = initialUrl,
       documentUrl = initialUrl,
       super.implementation();

  String? _url;
  String? documentUrl;
  String htmlDocument = '';
  bool hasDocumentElement = true;
  String? documentElementId;
  int networkNavigations = 0;
  final htmlLoadStarted = Completer<void>();
  final verificationReadyCheckStarted = Completer<void>();
  _FakeNavigationDelegate? _navigationDelegate;
  final Future<void> Function(LoadRequestParams params)? onLoadRequest;
  final Future<void> Function()? onLoadHtml;

  @override
  Future<String?> currentUrl() async => _url;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    _navigationDelegate = handler as _FakeNavigationDelegate;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    networkNavigations++;
    final url = params.uri.toString();
    final decision = await _navigationDelegate?.navigationRequest?.call(
      NavigationRequest(url: url, isMainFrame: true),
    );
    if (decision != NavigationDecision.prevent) {
      void finishNavigation() {
        _url = url;
        documentUrl = url;
        hasDocumentElement = true;
        documentElementId = null;
        _navigationDelegate?.pageFinished?.call(url);
      }

      final loading = onLoadRequest?.call(params);
      if (loading == null) {
        finishNavigation();
      } else {
        unawaited(loading.then((_) => finishNavigation()));
      }
    }
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    if (!htmlLoadStarted.isCompleted) htmlLoadStarted.complete();
    unawaited(() async {
      await onLoadHtml?.call();
      _url = 'about:blank';
      documentUrl = baseUrl;
      htmlDocument = html;
      hasDocumentElement = true;
      documentElementId = html.contains('kikoflu-browser-bridge')
          ? 'kikoflu-browser-bridge'
          : null;
      _navigationDelegate?.pageFinished?.call('about:blank');
    }());
  }

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {}

  @override
  Future<void> removeJavaScriptChannel(String javaScriptChannelName) async {}

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    if (javaScript.contains('location.origin')) {
      final source = isMissavVerificationUrl(documentUrl ?? '');
      return source &&
          (!javaScript.contains('kikoflu-browser-bridge') ||
              (hasDocumentElement &&
                  documentElementId == 'kikoflu-browser-bridge'));
    }
    if (javaScript.contains('document.readyState')) {
      if (!verificationReadyCheckStarted.isCompleted) {
        verificationReadyCheckStarted.complete();
      }
      return (!javaScript.contains('!!document.documentElement') ||
              hasDocumentElement) &&
          (!javaScript.contains(
                "document.documentElement.id !== 'kikoflu-browser-bridge'",
              ) ||
              documentElementId != 'kikoflu-browser-bridge');
    }
    return true;
  }

  @override
  Future<String?> getUserAgent() async => 'test-browser';
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? navigationRequest;
  PageEventCallback? pageFinished;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    navigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    pageFinished = onPageFinished;
  }

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

class _FakeCookieManager extends PlatformWebViewCookieManager {
  _FakeCookieManager(super.params, this.cookies, this.cookiesRequested)
    : super.implementation();

  final Future<List<WebViewCookie>> cookies;
  final Completer<void> cookiesRequested;

  @override
  Future<List<WebViewCookie>> getCookies(Uri url) {
    if (!cookiesRequested.isCompleted) cookiesRequested.complete();
    return cookies;
  }
}

class _MemorySecureStorage implements FlutterSecureStorage {
  int writeCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) return Future<String?>.value();
    if (invocation.memberName == #write) {
      writeCalls++;
      return Future<void>.value();
    }
    if (invocation.memberName == #delete) return Future<void>.value();
    return super.noSuchMethod(invocation);
  }
}

WebviewCookie _cookie(
  String name, {
  String domain = 'missav.ai',
  String path = '/',
  DateTime? expires,
  bool httpOnly = false,
  bool sessionOnly = false,
}) => WebviewCookie(
  name: name,
  value: 'value',
  domain: domain,
  path: path,
  expires: expires,
  secure: true,
  httpOnly: httpOnly,
  sessionOnly: sessionOnly,
);

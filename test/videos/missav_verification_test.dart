import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/missav_verification.dart';
import 'package:webview_flutter/webview_flutter.dart';
// This mock extends the transitive platform API used by webview_flutter.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

void main() {
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
  _FakeWebViewPlatform(this.cookies);

  final Future<List<WebViewCookie>> cookies;
  final cookiesRequested = Completer<void>();

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _FakeWebViewController(params);

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
  _FakeWebViewController(super.params) : super.implementation();

  String? _url = 'https://missav.ai/cn';
  _FakeNavigationDelegate? _navigationDelegate;

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
    _url = params.uri.toString();
    final decision = await _navigationDelegate?.navigationRequest?.call(
      NavigationRequest(url: _url!, isMainFrame: true),
    );
    if (decision != NavigationDecision.prevent) {
      _navigationDelegate?.pageFinished?.call(_url!);
    }
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
  Future<Object> runJavaScriptReturningResult(String javaScript) async => true;

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

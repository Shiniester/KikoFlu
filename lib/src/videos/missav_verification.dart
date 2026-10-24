import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../services/proxy_config.dart';
import '../utils/process_environment.dart';
import '../utils/global_keys.dart';
import 'missav_client.dart';
import 'missav_browser_adapter.dart';
import 'missav_browser_media.dart';
import 'missav_media_server.dart';
import 'video_models.dart';

const _androidBrowser = MethodChannel(
  'com.meteor.kikoeruflutter/missav_browser',
);

MissavBrowserAdapter? _activeBrowser;
MissavClient? _activeBrowserClient;
int? _activeBrowserClientGeneration;
int? _activeBrowserConnectionGeneration;
int? _activeBrowserAndroidProxyGeneration;
OverlayEntry? _activeMobileBrowserEntry;
WebViewController? _activeMobileBrowserController;
var _browserConnectionGeneration = 0;
var _androidProxyConfigurationGeneration = 0;

@visibleForTesting
Future<int> configureMissavAndroidProxy() async {
  final generation = ++_androidProxyConfigurationGeneration;
  try {
    await _androidBrowser.invokeMethod<void>('configureProxy', {
      'mode': ProxyConfig.mode.name,
      'proxyUrl': ProxyConfig.httpsProxyUrl,
    });
    return generation;
  } catch (_) {
    await releaseMissavAndroidProxy(generation);
    rethrow;
  }
}

@visibleForTesting
Future<void> releaseMissavAndroidProxy(int? generation) async {
  if (generation == null ||
      generation != _androidProxyConfigurationGeneration) {
    return;
  }
  _androidProxyConfigurationGeneration++;
  await _resetAndroidProxy();
}

String _cookieField(String value) =>
    value.endsWith('\u0000') ? value.substring(0, value.length - 1) : value;

Future<T> _cancelable<T>(Future<T> operation, Completer<void>? cancelSignal) {
  if (cancelSignal == null) return operation;
  if (cancelSignal.isCompleted) {
    return Future<T>.error(
      StateError('MissAV browser connection was cancelled.'),
    );
  }
  final cancelled = cancelSignal.future.then<T>(
    (_) => throw StateError('MissAV browser connection was cancelled.'),
  );
  return Future.any<T>([operation, cancelled]);
}

void _ensureConnectionCurrent(
  int generation,
  Completer<void>? cancelSignal, {
  MissavClient? client,
  int? clientGeneration,
}) {
  if (generation != _browserConnectionGeneration ||
      (cancelSignal?.isCompleted ?? false) ||
      (client != null &&
          clientGeneration != null &&
          client.sessionGeneration != clientGeneration)) {
    throw StateError('MissAV browser connection was cancelled.');
  }
}

void _clearBrowserOwner(MissavBrowserAdapter adapter) {
  if (!identical(_activeBrowser, adapter)) return;
  _activeBrowser = null;
  _activeBrowserClient = null;
  _activeBrowserClientGeneration = null;
  _activeBrowserConnectionGeneration = null;
  _activeBrowserAndroidProxyGeneration = null;
}

void _restoreOwnedBrowserTransport(
  MissavClient client,
  MissavBrowserAdapter adapter,
  int connectionGeneration,
) {
  if (connectionGeneration == _browserConnectionGeneration &&
      identical(_activeBrowser, adapter) &&
      identical(_activeBrowserClient, client) &&
      client.sessionGeneration == _activeBrowserClientGeneration) {
    client.restoreNativeTransport();
  }
}

Future<T> _awaitConnectionPhase<T>(
  Future<T> Function() operation,
  int generation,
  Completer<void>? cancelSignal, {
  MissavClient? client,
  int? clientGeneration,
}) async {
  _ensureConnectionCurrent(
    generation,
    cancelSignal,
    client: client,
    clientGeneration: clientGeneration,
  );
  final result = await _cancelable(operation(), cancelSignal);
  _ensureConnectionCurrent(
    generation,
    cancelSignal,
    client: client,
    clientGeneration: clientGeneration,
  );
  return result;
}

@visibleForTesting
bool isMissavVerificationUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri?.scheme == 'https' &&
      uri?.host == 'missav.ai' &&
      uri?.port == 443 &&
      uri?.userInfo.isEmpty == true;
}

@visibleForTesting
String missavVerificationCookieHeader(Iterable<WebviewCookie> cookies) {
  final now = DateTime.now();
  return cookies
      .where(
        (cookie) =>
            _cookieField(
                  cookie.domain,
                ).replaceFirst(RegExp(r'^\.'), '').toLowerCase() ==
                'missav.ai' &&
            _cookieField(cookie.path) == '/' &&
            (cookie.sessionOnly ||
                cookie.expires == null ||
                cookie.expires!.isAfter(now)),
      )
      // WebView2's UTF-16 conversion includes the terminating NUL.
      .map(
        (cookie) =>
            '${_cookieField(cookie.name)}=${_cookieField(cookie.value)}',
      )
      .join('; ');
}

Future<String> _desktopProfilePath() async =>
    p.join((await getApplicationSupportDirectory()).path, 'missav_browser');

Future<Webview> _createMissavDesktopBrowser({
  required bool hidden,
  Brightness? brightness,
}) async => WebviewWindow.create(
  configuration: CreateConfiguration(
    title: 'MissAV',
    windowWidth: 1080,
    windowHeight: 800,
    openHidden: hidden,
    brightness: brightness,
    windows: WindowsWebviewOptions(
      userDataFolder: await _desktopProfilePath(),
      denyCameraAndMicrophone: true,
    ),
  ),
);

Future<void> _waitForDesktopPage(
  Webview browser,
  String url, {
  Completer<void>? cancelSignal,
}) async {
  final completed = Completer<void>();
  void observeNavigation() {
    final state = browser.navigationState.value;
    final currentUrl = state.url;
    if (state.isLoading) {
      if (currentUrl != null && !isMissavVerificationUrl(currentUrl)) {
        if (!completed.isCompleted) {
          completed.completeError(StateError('MissAV navigation was blocked.'));
        }
      }
    } else if (currentUrl != null && isMissavVerificationUrl(currentUrl)) {
      if (!completed.isCompleted) completed.complete();
    }
  }

  final errors = browser.onLoadError.listen((error) {
    if (isMissavVerificationUrl(error.url) && !completed.isCompleted) {
      completed.completeError(StateError('MissAV could not be loaded.'));
    }
  });
  browser.navigationState.addListener(observeNavigation);
  try {
    await _cancelable(
      Future.wait<void>([
        browser.navigationState.value.url == url
            ? browser.reload()
            : browser.launch(url),
        completed.future.timeout(const Duration(seconds: 30)),
      ], eagerError: true),
      cancelSignal,
    );
    await _waitForBrowserVerification(
      () => browser.evaluateJavaScript(_verificationReadyScript),
      url,
      cancelSignal,
    );
  } finally {
    browser.navigationState.removeListener(observeNavigation);
    await errors.cancel();
  }
}

@visibleForTesting
Future<void> waitForMissavMobilePage(
  WebViewController controller,
  String url, {
  Completer<void>? cancelSignal,
  required void Function() ensureActive,
}) async {
  final completed = Completer<void>();
  ensureActive();
  await controller.setNavigationDelegate(
    NavigationDelegate(
      onNavigationRequest: (request) =>
          !request.isMainFrame || isMissavVerificationUrl(request.url)
          ? NavigationDecision.navigate
          : NavigationDecision.prevent,
      onPageFinished: (pageUrl) {
        if (isMissavVerificationUrl(pageUrl) && !completed.isCompleted) {
          completed.complete();
        }
      },
      onWebResourceError: (error) {
        if (error.isForMainFrame != false &&
            isMissavVerificationUrl(error.url ?? '') &&
            !completed.isCompleted) {
          completed.completeError(StateError('MissAV could not be loaded.'));
        }
      },
    ),
  );
  ensureActive();
  await _cancelable(
    Future.wait<void>([
      controller.loadRequest(Uri.parse(url)),
      completed.future.timeout(const Duration(seconds: 30)),
    ], eagerError: true),
    cancelSignal,
  );
  ensureActive();
  await _waitForBrowserVerification(
    () => controller.runJavaScriptReturningResult(_verificationReadyScript),
    url,
    cancelSignal,
  );
}

const _verificationReadyScript = '''
document.readyState === 'complete' && typeof window._cf_chl_opt === 'undefined' &&
!/^Just a moment|Attention Required.*Cloudflare/i.test(document.title)
''';

Future<void> _waitForBrowserVerification(
  Future<Object?> Function() ready,
  String url,
  Completer<void>? cancelSignal,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final result = await _cancelable(ready(), cancelSignal);
    if (result == true || result == 'true') return;
    await _cancelable(
      Future<void>.delayed(const Duration(milliseconds: 250)),
      cancelSignal,
    );
  }
  throw MissavVerificationRequiredException(sourceUrl: url);
}

const _documentMarkupScript = '''
(() => {
  const pause = media => { media.muted = true; media.pause(); };
  document.querySelectorAll('video, audio').forEach(pause);
  document.addEventListener('play', event => {
    if (event.target instanceof HTMLMediaElement) pause(event.target);
  }, true);
  return JSON.stringify({url:location.href, html:document.documentElement.outerHTML});
})()
''';

@visibleForTesting
Future<void> stopMissavDesktopNavigation(Webview browser) async {
  final stopped = Completer<void>();
  void observe() {
    if (!browser.navigationState.value.isLoading && !stopped.isCompleted) {
      stopped.complete();
    }
  }

  browser.navigationState.addListener(observe);
  try {
    await browser.stop();
    observe();
    await Future.any<void>([stopped.future, browser.onClose]).timeout(
      const Duration(seconds: 30),
      onTimeout: () async {
        await browser.close();
        await browser.onClose;
        throw StateError('MissAV navigation could not be stopped.');
      },
    );
  } finally {
    browser.navigationState.removeListener(observe);
  }
}

@visibleForTesting
Future<String> navigateMissavDocument(
  Uri uri,
  Future<void> cancelled, {
  required Future<void> Function(Completer<void> signal) navigate,
  required Future<Object?> Function(String script) read,
  required Future<void> Function() stop,
}) async {
  final cancellation = Completer<void>();
  var finished = false;
  Future<void> stopping = Future.value();
  unawaited(
    cancelled.then((_) {
      if (finished) return;
      cancellation.complete();
      stopping = Future<void>.sync(stop);
      stopping.ignore();
    }),
  );
  try {
    await navigate(cancellation);
    final raw = await _cancelable(read(_documentMarkupScript), cancellation);
    var document = raw is String ? jsonDecode(raw) : raw;
    // Android WebView JSON-encodes JavaScript string results once more.
    if (document is String) document = jsonDecode(document);
    if (document is! Map ||
        document['html'] is! String ||
        !isMissavVerificationUrl('${document['url'] ?? ''}')) {
      throw MissavException(
        'MissAV browser did not return a source document.',
        sourceUrl: uri.toString(),
      );
    }
    return document['html'] as String;
  } catch (_) {
    if (!cancellation.isCompleted) {
      stopping = Future<void>.sync(stop);
      stopping.ignore();
    }
    rethrow;
  } finally {
    finished = true;
    await stopping;
  }
}

String _webViewCookieHeader(Iterable<WebViewCookie> cookies) => cookies
    .where(
      (cookie) =>
          _cookieField(
                cookie.domain,
              ).replaceFirst(RegExp(r'^\.'), '').toLowerCase() ==
              'missav.ai' &&
          _cookieField(cookie.path) == '/',
    )
    .map(
      (cookie) => '${_cookieField(cookie.name)}=${_cookieField(cookie.value)}',
    )
    .join('; ');

Future<String> _mobileCookieHeader() async {
  if (Platform.isAndroid) {
    return await _androidBrowser.invokeMethod<String>('getCookies') ?? '';
  }
  final cookies = await WebViewCookieManager().getCookies(
    domain: Uri.parse('${MissavClient.origin}/'),
  );
  return _webViewCookieHeader(cookies);
}

Future<void> _disposeDesktopBrowser(Webview browser) async {
  try {
    await browser.evaluateJavaScript('''
for (const controller of window.__kikoMissavRequests?.values() ?? []) controller.abort();
window.__kikoMissavRequests?.clear();
''');
  } catch (_) {
    // Closing a browser may already have stopped its page scripts.
  }
  browser.removeJavaScriptHandler(MissavBrowserAdapter.channelName);
  try {
    await browser.setOnUrlRequestCallback(null);
  } catch (_) {}
  try {
    await browser.launch('about:blank', triggerOnUrlRequestEvent: false);
  } catch (_) {}
  try {
    await browser.close();
  } catch (_) {}
  await browser.onClose;
}

Future<void> _resetAndroidProxy() async {
  try {
    await _androidBrowser.invokeMethod<void>('resetProxy');
  } catch (_) {
    // Proxy reset is best-effort when a browser route is already closing.
  }
}

Future<void> _disposeMobileBrowser(
  WebViewController controller, {
  required bool preservePage,
  String channelName = MissavBrowserAdapter.channelName,
}) async {
  try {
    await controller.runJavaScript('window.stop();');
  } catch (_) {}
  try {
    await controller.runJavaScript('''
for (const request of window.__kikoMissavRequests?.values() ?? []) request.abort();
window.__kikoMissavRequests?.clear();
''');
  } catch (_) {}
  try {
    await controller.removeJavaScriptChannel(channelName);
  } catch (_) {}
  try {
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) =>
            !request.isMainFrame ||
                isMissavVerificationUrl(request.url) ||
                request.url == 'about:blank'
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ),
    );
  } catch (_) {}

  if (!preservePage) {
    try {
      await controller.setNavigationDelegate(NavigationDelegate());
    } catch (_) {}
    try {
      await controller.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
    if (identical(_activeMobileBrowserController, controller)) {
      _activeMobileBrowserController = null;
      _activeMobileBrowserEntry?.remove();
      _activeMobileBrowserEntry = null;
    }
  }
}

Future<({MissavMediaServer server, MissavBrowserMediaTransport transport})>
_createMissavMediaRelay({
  required bool mobile,
  required String homeUrl,
  required void Function() ensureActive,
  Completer<void>? cancelSignal,
}) async {
  Webview? desktop;
  WebViewController? controller;
  OverlayEntry? entry;
  MissavBrowserMediaTransport? transport;
  Future<void> disposeMobile() async {
    final browser = controller;
    if (browser == null) return;
    try {
      await _disposeMobileBrowser(
        browser,
        preservePage: false,
        channelName: MissavBrowserMediaTransport.channelName,
      );
    } finally {
      entry?.remove();
      entry?.dispose();
      entry = null;
    }
  }

  final startUrl =
      '${MissavClient.origin}/${Uri.parse(homeUrl).pathSegments.last}';
  try {
    ensureActive();
    if (!mobile) {
      final browser = await _createMissavDesktopBrowser(hidden: true);
      desktop = browser;
      ensureActive();
      final media = MissavBrowserMediaTransport(
        runJavaScript: (script) async {
          await browser.evaluateJavaScript(script);
        },
        currentUrl: () async => browser.navigationState.value.url,
        disposeBrowser: () async {
          browser.removeJavaScriptHandler(
            MissavBrowserMediaTransport.channelName,
          );
          await _disposeDesktopBrowser(browser);
        },
      );
      transport = media;
      browser.addJavaScriptHandler(
        MissavBrowserMediaTransport.channelName,
        (message, origin) => media.receiveMessage(message, origin: origin),
      );
      unawaited(browser.onClose.then((_) => media.close()));
      await browser.setOnUrlRequestCallback(isMissavVerificationUrl);
      ensureActive();
      await _waitForDesktopPage(browser, startUrl, cancelSignal: cancelSignal);
      ensureActive();
    } else {
      final browser = WebViewController();
      controller = browser;
      await browser.setJavaScriptMode(JavaScriptMode.unrestricted);
      ensureActive();
      final overlay = rootNavigatorKey.currentState?.overlay;
      if (overlay == null) throw StateError('Application overlay unavailable');
      final view = OverlayEntry(
        builder: (_) => Offstage(
          child: SizedBox(
            width: 1,
            height: 1,
            child: WebViewWidget(controller: browser),
          ),
        ),
      );
      overlay.insert(view);
      entry = view;
      await WidgetsBinding.instance.endOfFrame;
      ensureActive();
      final media = MissavBrowserMediaTransport(
        runJavaScript: browser.runJavaScript,
        currentUrl: browser.currentUrl,
        disposeBrowser: disposeMobile,
      );
      transport = media;
      await browser.addJavaScriptChannel(
        MissavBrowserMediaTransport.channelName,
        onMessageReceived: (message) => media.receiveMessage(message.message),
      );
      ensureActive();
      await waitForMissavMobilePage(
        browser,
        startUrl,
        cancelSignal: cancelSignal,
        ensureActive: ensureActive,
      );
      ensureActive();
    }
    final media = transport;
    final server = await MissavMediaServer.start(media);
    try {
      ensureActive();
    } catch (_) {
      await server.close();
      rethrow;
    }
    return (server: server, transport: media);
  } catch (_) {
    if (transport != null) {
      transport.close();
      await transport.whenClosed;
    } else if (desktop != null) {
      await _disposeDesktopBrowser(desktop);
    } else if (controller != null) {
      await disposeMobile();
    }
    rethrow;
  }
}

Future<void> connectMissavBrowserSession(
  MissavClient client, {
  WebViewController? mobile,
  Completer<void>? cancelSignal,
  int? expectedGeneration,
  int? androidProxyGeneration,
  bool preserveMobilePageOnFailure = true,
}) async {
  if (expectedGeneration != null &&
      client.sessionGeneration != expectedGeneration) {
    throw StateError('MissAV browser connection was cancelled.');
  }
  final connectionGeneration = ++_browserConnectionGeneration;
  final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  if (mobile == null && !isDesktop) {
    throw StateError('A mobile MissAV WebView is required.');
  }
  if (!Platform.isWindows &&
      !Platform.isAndroid &&
      ProxyConfig.mode != ProxyMode.system) {
    throw StateError('MissAV verification requires the system proxy.');
  }

  Webview? desktop;
  MissavBrowserAdapter? adapter;
  ({MissavMediaServer server, MissavBrowserMediaTransport transport})?
  mediaRelay;
  Future<void> closeMedia() async {
    final relay = mediaRelay;
    mediaRelay = null;
    if (relay == null) return;
    relay.transport.close();
    try {
      await relay.server.close();
    } finally {
      await relay.transport.whenClosed;
    }
  }

  var preserveMobilePage = false;
  var connected = false;
  var proxyGeneration = androidProxyGeneration;
  late int clientGeneration;
  try {
    await _awaitConnectionPhase(
      client.initialize,
      connectionGeneration,
      cancelSignal,
    );
    clientGeneration = expectedGeneration ?? client.sessionGeneration;
    _ensureConnectionCurrent(
      connectionGeneration,
      cancelSignal,
      client: client,
      clientGeneration: clientGeneration,
    );
    final previous = _activeBrowser;
    if (previous != null) {
      if (identical(_activeBrowserClient, client) &&
          clientGeneration == _activeBrowserClientGeneration) {
        client.restoreNativeTransport();
        clientGeneration = client.sessionGeneration;
      }
      previous.close(force: true);
      try {
        await previous.whenClosed;
      } finally {
        _clearBrowserOwner(previous);
      }
      _ensureConnectionCurrent(
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      );
    }

    _ensureConnectionCurrent(
      connectionGeneration,
      cancelSignal,
      client: client,
      clientGeneration: clientGeneration,
    );
    if (Platform.isAndroid) {
      proxyGeneration ??= await configureMissavAndroidProxy();
      if (proxyGeneration != _androidProxyConfigurationGeneration) {
        throw StateError('MissAV browser proxy was replaced.');
      }
      _ensureConnectionCurrent(
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      );
    }

    String cookieHeader;
    String? userAgent;
    if (mobile == null) {
      final available = await _awaitConnectionPhase(
        WebviewWindow.isWebviewAvailable,
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      );
      if (!available) throw StateError('WebView runtime unavailable');
      if (Platform.isWindows) {
        final proxy = ProxyConfig.httpsProxyUrl;
        setProcessEnvironment(
          'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
          proxy != null
              ? '--proxy-server=$proxy'
              : ProxyConfig.mode == ProxyMode.direct
              ? '--no-proxy-server'
              : '',
        );
      }
      final browser = await _createMissavDesktopBrowser(hidden: true);
      desktop = browser;
      _ensureConnectionCurrent(
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      );
      late final MissavBrowserAdapter browserAdapter;
      var disposing = false;
      browserAdapter = MissavBrowserAdapter(
        runJavaScript: (script) async {
          await browser.evaluateJavaScript(script);
        },
        currentUrl: () async => browser.navigationState.value.url,
        navigateDocument: (uri, cancelled) => navigateMissavDocument(
          uri,
          cancelled,
          navigate: (signal) => _waitForDesktopPage(
            browser,
            uri.toString(),
            cancelSignal: signal,
          ),
          read: browser.evaluateJavaScript,
          stop: () => stopMissavDesktopNavigation(browser),
        ),
        disposeBrowser: () async {
          disposing = true;
          await closeMedia();
          await _disposeDesktopBrowser(browser);
          _clearBrowserOwner(browserAdapter);
        },
      );
      adapter = browserAdapter;
      browser.addJavaScriptHandler(
        MissavBrowserAdapter.channelName,
        (message, origin) =>
            browserAdapter.receiveMessage(message, origin: origin),
      );
      unawaited(
        browser.onClose.then((_) {
          if (!disposing) browserAdapter.close(force: true);
        }),
      );
      await _awaitConnectionPhase(
        () => browser.setOnUrlRequestCallback(isMissavVerificationUrl),
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      );
      await _awaitConnectionPhase(
        () => _waitForDesktopPage(
          browser,
          client.homeUrl,
          cancelSignal: cancelSignal,
        ),
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      );
      cookieHeader = missavVerificationCookieHeader(
        await _awaitConnectionPhase(
          browser.getAllCookies,
          connectionGeneration,
          cancelSignal,
          client: client,
          clientGeneration: clientGeneration,
        ),
      );
      final browserAgent = await _awaitConnectionPhase(
        () => browser.evaluateJavaScript('navigator.userAgent'),
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      );
      userAgent = browserAgent is String ? browserAgent : null;
    } else {
      late final MissavBrowserAdapter browserAdapter;
      browserAdapter = MissavBrowserAdapter(
        runJavaScript: mobile.runJavaScript,
        currentUrl: mobile.currentUrl,
        navigateDocument: (uri, cancelled) => navigateMissavDocument(
          uri,
          cancelled,
          navigate: (signal) => waitForMissavMobilePage(
            mobile,
            uri.toString(),
            cancelSignal: signal,
            ensureActive: () {
              if (signal.isCompleted) {
                throw StateError('MissAV navigation was cancelled.');
              }
            },
          ),
          read: mobile.runJavaScriptReturningResult,
          stop: () => mobile.runJavaScript('window.stop();'),
        ),
        disposeBrowser: () async {
          await closeMedia();
          await _disposeMobileBrowser(mobile, preservePage: preserveMobilePage);
          final proxyToRelease = identical(_activeBrowser, browserAdapter)
              ? _activeBrowserAndroidProxyGeneration
              : null;
          _clearBrowserOwner(browserAdapter);
          if (Platform.isAndroid && !preserveMobilePage) {
            await releaseMissavAndroidProxy(proxyToRelease);
          }
        },
      );
      adapter = browserAdapter;
      await _awaitConnectionPhase(
        () => mobile.addJavaScriptChannel(
          MissavBrowserAdapter.channelName,
          onMessageReceived: (message) =>
              browserAdapter.receiveMessage(message.message),
        ),
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      );
      await _awaitConnectionPhase(
        () => waitForMissavMobilePage(
          mobile,
          client.homeUrl,
          cancelSignal: cancelSignal,
          ensureActive: () => _ensureConnectionCurrent(
            connectionGeneration,
            cancelSignal,
            client: client,
            clientGeneration: clientGeneration,
          ),
        ),
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      );
      final currentUrl = await _awaitConnectionPhase(
        mobile.currentUrl,
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      );
      if (!isMissavVerificationUrl(currentUrl ?? '')) {
        throw StateError('Source browser unavailable');
      }
      cookieHeader = await _awaitConnectionPhase(
        _mobileCookieHeader,
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      );
      userAgent = await _awaitConnectionPhase(
        mobile.getUserAgent,
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      );
    }

    if (cookieHeader.isEmpty || userAgent == null || userAgent.isEmpty) {
      throw StateError('Source browser session unavailable');
    }
    _ensureConnectionCurrent(
      connectionGeneration,
      cancelSignal,
      client: client,
      clientGeneration: clientGeneration,
    );
    final generationBeforeImport = clientGeneration;
    await client.importVerifiedSession(
      cookieHeader: cookieHeader,
      userAgent: userAgent,
      expectedGeneration: generationBeforeImport,
    );
    if (client.sessionGeneration != generationBeforeImport + 1) {
      throw StateError('MissAV session changed during browser verification.');
    }
    _ensureConnectionCurrent(
      connectionGeneration,
      cancelSignal,
      client: client,
      clientGeneration: generationBeforeImport + 1,
    );
    clientGeneration = client.sessionGeneration;

    final relay = await _createMissavMediaRelay(
      mobile: mobile != null,
      homeUrl: client.homeUrl,
      cancelSignal: cancelSignal,
      ensureActive: () => _ensureConnectionCurrent(
        connectionGeneration,
        cancelSignal,
        client: client,
        clientGeneration: clientGeneration,
      ),
    );
    mediaRelay = relay;

    final connectedAdapter = adapter;
    _ensureConnectionCurrent(
      connectionGeneration,
      cancelSignal,
      client: client,
      clientGeneration: clientGeneration,
    );
    unawaited(
      relay.transport.whenClosed.then(
        (_) => connectedAdapter.close(force: true),
      ),
    );
    client.useVerifiedBrowserTransport(
      connectedAdapter,
      mediaRoute: relay.server.register,
    );
    _activeBrowser = connectedAdapter;
    _activeBrowserClient = client;
    clientGeneration = client.sessionGeneration;
    _activeBrowserClientGeneration = clientGeneration;
    _activeBrowserConnectionGeneration = connectionGeneration;
    _activeBrowserAndroidProxyGeneration = proxyGeneration;
    await _awaitConnectionPhase(
      client.checkBrowserAccess,
      connectionGeneration,
      cancelSignal,
      client: client,
      clientGeneration: clientGeneration,
    );
    connected = true;
  } catch (_) {
    preserveMobilePage = mobile != null && preserveMobilePageOnFailure;
    if (adapter != null) {
      _restoreOwnedBrowserTransport(client, adapter, connectionGeneration);
      adapter.close(force: true);
      try {
        await adapter.whenClosed;
      } catch (_) {}
    } else if (desktop != null) {
      await _disposeDesktopBrowser(desktop);
    }
    rethrow;
  } finally {
    if (Platform.isAndroid && !connected && !preserveMobilePageOnFailure) {
      await releaseMissavAndroidProxy(proxyGeneration);
    }
  }
}

Future<void> restoreMissavBrowserSession(
  MissavClient client,
  int expectedGeneration,
) async {
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await connectMissavBrowserSession(
      client,
      expectedGeneration: expectedGeneration,
      preserveMobilePageOnFailure: false,
    );
    return;
  }

  final connectionGeneration = _browserConnectionGeneration;
  void ensureCurrent() => _ensureConnectionCurrent(
    connectionGeneration,
    null,
    client: client,
    clientGeneration: expectedGeneration,
  );
  ensureCurrent();
  final overlay = rootNavigatorKey.currentState?.overlay;
  if (overlay == null) throw StateError('Application overlay unavailable');
  final mobile = WebViewController();
  OverlayEntry? entry;
  var retained = false;
  try {
    await mobile.setJavaScriptMode(JavaScriptMode.unrestricted);
    ensureCurrent();
    entry = OverlayEntry(
      builder: (_) => Offstage(
        child: SizedBox(
          width: 1,
          height: 1,
          child: WebViewWidget(controller: mobile),
        ),
      ),
    );
    overlay.insert(entry);
    await WidgetsBinding.instance.endOfFrame;
    ensureCurrent();
    await connectMissavBrowserSession(
      client,
      mobile: mobile,
      expectedGeneration: expectedGeneration,
      preserveMobilePageOnFailure: false,
    );
    if (_activeBrowser == null || !identical(_activeBrowserClient, client)) {
      throw StateError('MissAV browser recovery was replaced.');
    }
    _activeMobileBrowserController = mobile;
    _activeMobileBrowserEntry = entry;
    entry = null;
    retained = true;
  } finally {
    if (!retained) {
      await _disposeMobileBrowser(mobile, preservePage: false);
      entry?.remove();
      entry?.dispose();
    }
  }
}

Future<bool> verifyMissavAccess(
  BuildContext context,
  MissavClient client, {
  required String sourceUrl,
}) async {
  if (!isMissavVerificationUrl(sourceUrl)) return false;
  final pageUrl = Uri.parse(sourceUrl).pathSegments.contains('api')
      ? client.homeUrl
      : sourceUrl;
  int? proxyGeneration;
  try {
    if (Platform.isAndroid) {
      proxyGeneration = await configureMissavAndroidProxy();
    }
    if (!context.mounted) return false;
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MissavVerification(
        client: client,
        sourceUrl: pageUrl,
        androidProxyGeneration: proxyGeneration,
      ),
    );
    return verified ?? false;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(S.of(context).videoSourceUnavailable)),
      );
    }
    return false;
  } finally {
    if (Platform.isAndroid &&
        proxyGeneration != null &&
        proxyGeneration == _androidProxyConfigurationGeneration) {
      if (_activeBrowser == null) {
        await releaseMissavAndroidProxy(proxyGeneration);
      } else {
        _activeBrowserAndroidProxyGeneration = proxyGeneration;
      }
    }
  }
}

Future<void> clearMissavBrowserSession() async {
  final generation = ++_browserConnectionGeneration;
  final active = _activeBrowser;
  _activeBrowser = null;
  _activeBrowserClient = null;
  _activeBrowserClientGeneration = null;
  _activeBrowserConnectionGeneration = null;
  _activeBrowserAndroidProxyGeneration = null;
  active?.close(force: true);
  await active?.whenClosed;
  if (generation != _browserConnectionGeneration || _activeBrowser != null) {
    return;
  }
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    final profilePath = await _desktopProfilePath();
    if (generation != _browserConnectionGeneration || _activeBrowser != null) {
      return;
    }
    await WebviewWindow.clearAll(
      windows: WindowsWebviewOptions(userDataFolder: profilePath),
    );
  } else if (Platform.isAndroid) {
    _androidProxyConfigurationGeneration++;
    await _resetAndroidProxy();
    if (generation != _browserConnectionGeneration || _activeBrowser != null) {
      return;
    }
    await _androidBrowser.invokeMethod<void>('clearSession');
  } else {
    final manager = WebViewCookieManager();
    final cookies = await manager.getCookies(
      domain: Uri.parse('${MissavClient.origin}/'),
    );
    for (final cookie in cookies) {
      // Preserve other sources' WebView sessions, including Japanese ASMR.
      await manager.setCookie(
        WebViewCookie(
          name: cookie.name,
          value: '',
          domain: cookie.domain,
          path: cookie.path,
        ),
      );
    }
  }
}

class _MissavVerification extends StatefulWidget {
  const _MissavVerification({
    required this.client,
    required this.sourceUrl,
    this.androidProxyGeneration,
  });

  final MissavClient client;
  final String sourceUrl;
  final int? androidProxyGeneration;

  @override
  State<_MissavVerification> createState() => _MissavVerificationState();
}

class _MissavVerificationState extends State<_MissavVerification> {
  final _mobileViewKey = GlobalKey();
  Webview? _desktop;
  StreamSubscription<WebviewLoadError>? _desktopLoadErrors;
  WebViewController? _mobile;
  Future<void>? _mobileCleanup;
  bool _starting = true;
  bool _checking = false;
  bool _failed = false;
  bool _closed = false;
  bool _finished = false;
  bool _proxyUnsupported = false;
  bool _mobileRetained = false;
  bool _connectingBrowser = false;
  Completer<void>? _connectCancellation;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      // shortcut: Other platform WebViews follow the system proxy. Add native
      // proxy overrides when those platforms need manual-proxy verification.
      if (!Platform.isWindows &&
          !Platform.isAndroid &&
          ProxyConfig.mode != ProxyMode.system) {
        if (mounted) {
          setState(() {
            _starting = false;
            _proxyUnsupported = true;
          });
        }
        return;
      }
      if (_isDesktop) {
        if (!await WebviewWindow.isWebviewAvailable()) {
          throw StateError('WebView runtime unavailable');
        }
        if (Platform.isWindows) {
          final proxy = ProxyConfig.httpsProxyUrl;
          setProcessEnvironment(
            'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
            proxy != null
                ? '--proxy-server=$proxy'
                : ProxyConfig.mode == ProxyMode.direct
                ? '--no-proxy-server'
                : '',
          );
        }
        final browser = await _createMissavDesktopBrowser(
          hidden: false,
          brightness: mounted ? Theme.of(context).brightness : null,
        );
        if (!mounted) {
          await browser.close();
          return;
        }
        _desktop = browser;
        await browser.setOnUrlRequestCallback(isMissavVerificationUrl);
        _desktopLoadErrors = browser.onLoadError.listen((_) {
          if (mounted) setState(() => _failed = true);
        });
        unawaited(
          browser.onClose.then((_) {
            _closed = true;
            if (_connectingBrowser &&
                !(_connectCancellation?.isCompleted ?? true)) {
              _connectCancellation!.complete();
            }
            if (!_checking) _finish(false);
          }),
        );
        await browser.launch(widget.sourceUrl);
      } else {
        final controller = WebViewController();
        _mobile = controller;
        await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
        if (!mounted) {
          await _closeUnretainedMobileController();
          return;
        }
        await controller.setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) =>
                !request.isMainFrame || isMissavVerificationUrl(request.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
            onWebResourceError: (error) {
              if (error.isForMainFrame == true && mounted) {
                setState(() => _failed = true);
              }
            },
          ),
        );
        if (!mounted) {
          await _closeUnretainedMobileController();
          return;
        }
        await controller.loadRequest(Uri.parse(widget.sourceUrl));
        if (!mounted) {
          await _closeUnretainedMobileController();
          return;
        }
      }
      if (mounted) setState(() => _starting = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _starting = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _failed = false;
    });
    try {
      await widget.client.initialize();
      if (!mounted || _closed) throw StateError('Verification window closed.');
      final cancellation = Completer<void>();
      _connectCancellation = cancellation;
      if (mounted) setState(() => _connectingBrowser = true);
      try {
        final connection = connectMissavBrowserSession(
          widget.client,
          mobile: _isDesktop ? null : _mobile,
          cancelSignal: cancellation,
          androidProxyGeneration: widget.androidProxyGeneration,
        );
        final connectionGeneration = _browserConnectionGeneration;
        await connection;
        final browserAdapter = _activeBrowser;
        if (browserAdapter == null ||
            _activeBrowserConnectionGeneration != connectionGeneration) {
          throw StateError('Verification connection was replaced.');
        }
        if (!mounted || _closed || cancellation.isCompleted) {
          _restoreOwnedBrowserTransport(
            widget.client,
            browserAdapter,
            connectionGeneration,
          );
          try {
            await browserAdapter.whenClosed;
          } catch (_) {}
          throw StateError('Verification was cancelled.');
        }
        if (_isDesktop) {
          final browser = _desktop;
          if (browser != null) {
            try {
              await browser.close();
              await browser.onClose;
            } catch (_) {}
          }
        } else {
          try {
            _retainMobileBrowser();
          } catch (_) {
            _restoreOwnedBrowserTransport(
              widget.client,
              browserAdapter,
              connectionGeneration,
            );
            try {
              await browserAdapter.whenClosed;
            } catch (_) {}
            rethrow;
          }
        }
      } finally {
        if (identical(_connectCancellation, cancellation)) {
          _connectCancellation = null;
        }
        if (mounted) setState(() => _connectingBrowser = false);
      }
      _finish(true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _checking = false);
        if (_closed) _finish(false);
      }
    }
  }

  void _retainMobileBrowser() {
    final controller = _mobile;
    if (controller == null || _mobileRetained) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (_) => Offstage(
        child: SizedBox(
          width: 1,
          height: 1,
          child: WebViewWidget(key: _mobileViewKey, controller: controller),
        ),
      ),
    );
    _activeMobileBrowserController = controller;
    _activeMobileBrowserEntry = entry;
    overlay.insert(entry);
    setState(() => _mobileRetained = true);
  }

  Future<void> _closeUnretainedMobileController() {
    if (_mobileRetained) return Future.value();
    final controller = _mobile;
    if (controller == null) return Future.value();
    return _mobileCleanup ??= _disposeMobileBrowser(
      controller,
      preservePage: false,
    );
  }

  void _finish(bool verified) {
    if (!mounted || _finished) return;
    _finished = true;
    Navigator.of(context).pop(verified);
  }

  void _cancelVerification() {
    if (_connectingBrowser) {
      final cancellation = _connectCancellation;
      if (cancellation != null && !cancellation.isCompleted) {
        cancellation.complete();
      }
      _finish(false);
    } else if (!_checking) {
      _finish(false);
    }
  }

  @override
  void dispose() {
    final cancellation = _connectCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    unawaited(_desktopLoadErrors?.cancel());
    final browser = _desktop;
    if (browser != null && !_closed) unawaited(browser.close());
    unawaited(_closeUnretainedMobileController());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return PopScope(
      canPop: !_checking || _connectingBrowser,
      child: AlertDialog(
        title: Text(s.videoVerifyAccess),
        content: SizedBox(
          width: _isDesktop ? 420 : 720,
          height: _isDesktop ? null : MediaQuery.sizeOf(context).height * .65,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(s.videoVerificationHelp),
              if (_starting) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
              if (_proxyUnsupported) ...[
                const SizedBox(height: 12),
                Text(s.videoVerificationSystemProxyRequired),
              ],
              if (_failed) ...[
                const SizedBox(height: 12),
                Text(
                  s.videoVerificationFailed,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (!_isDesktop && _mobile != null && !_mobileRetained) ...[
                const SizedBox(height: 12),
                Expanded(
                  child: WebViewWidget(
                    key: _mobileViewKey,
                    controller: _mobile!,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _checking && !_connectingBrowser
                ? null
                : _cancelVerification,
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: _starting || _checking || _proxyUnsupported
                ? null
                : _check,
            child: _checking
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(s.videoVerificationContinue),
          ),
        ],
      ),
    );
  }
}

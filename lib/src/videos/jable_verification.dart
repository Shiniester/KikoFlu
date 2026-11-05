import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../services/proxy_config.dart';
import '../utils/global_keys.dart';
import '../utils/process_environment.dart';
import '../utils/snackbar_util.dart';
import 'jable_client.dart';
import 'missav_browser_adapter.dart';
import 'video_models.dart';

const _androidBrowser = MethodChannel(
  'com.meteor.kikoeruflutter/jable_browser',
);
var _androidProxyGeneration = 0;
MissavBrowserAdapter? _activeJableBrowser;
JableClient? _activeJableBrowserClient;
int? _activeJableAndroidProxyGeneration;
var _jableBrowserConnectionGeneration = 0;

@visibleForTesting
class JableBrowserConnectionLifetime {
  JableBrowserConnectionLifetime(this._client);

  final JableClient _client;
  final Completer<void> _cancelled = Completer<void>();
  int? _importedGeneration;
  bool _handedOff = false;

  Future<void> get cancelSignal => _cancelled.future;
  bool get isCancelled => _cancelled.isCompleted;
  bool get isHandedOff => _handedOff;

  void sessionImported(int generation) => _importedGeneration = generation;

  Future<void> discardImportedSession() async {
    final generation = _importedGeneration;
    _importedGeneration = null;
    if (generation != null) {
      await _client.clearSession(expectedGeneration: generation);
    }
  }

  void handoff() {
    _importedGeneration = null;
    _handedOff = true;
  }

  Future<void> cancel() async {
    if (_handedOff || _cancelled.isCompleted) return;
    _cancelled.complete();
    await discardImportedSession();
  }
}

@visibleForTesting
bool isJableVerificationUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri?.scheme == 'https' &&
      uri?.host == 'jable.tv' &&
      uri?.port == 443 &&
      uri?.userInfo.isEmpty == true;
}

@visibleForTesting
String jableDocumentMarkup(Object? result, {required bool android}) {
  if (result is! String) {
    throw const VideoSourceException(
      'Jable browser returned an invalid document.',
      sourceKey: 'jable',
    );
  }
  if (!android) return result;
  try {
    final decoded = jsonDecode(result);
    if (decoded is String) return decoded;
  } on FormatException {
    // Android WebView returns evaluateJavascript strings as JSON text.
  }
  throw const VideoSourceException(
    'Jable browser returned an invalid document.',
    sourceKey: 'jable',
  );
}

@visibleForTesting
String jableVerificationCookieHeader(Iterable<WebviewCookie> cookies) {
  final now = DateTime.now();
  return cookies
      .where(
        (cookie) =>
            _cookieField(
                  cookie.domain,
                ).replaceFirst(RegExp(r'^\.'), '').toLowerCase() ==
                'jable.tv' &&
            _cookieField(cookie.path) == '/' &&
            (cookie.sessionOnly ||
                cookie.expires == null ||
                cookie.expires!.isAfter(now)),
      )
      .map(
        (cookie) =>
            '${_cookieField(cookie.name)}=${_cookieField(cookie.value)}',
      )
      .join('; ');
}

String _cookieField(String value) =>
    value.endsWith('\u0000') ? value.substring(0, value.length - 1) : value;

Future<String> _desktopProfilePath() async =>
    p.join((await getApplicationSupportDirectory()).path, 'jable_browser');

Future<int> _configureAndroidProxy() async {
  final generation = ++_androidProxyGeneration;
  try {
    await _androidBrowser.invokeMethod<void>('configureProxy', {
      'mode': ProxyConfig.mode.name,
      'proxyUrl': ProxyConfig.httpsProxyUrl,
    });
    return generation;
  } catch (_) {
    await _releaseAndroidProxy(generation);
    rethrow;
  }
}

Future<void> _releaseAndroidProxy(int generation) async {
  if (generation != _androidProxyGeneration) return;
  _androidProxyGeneration++;
  try {
    await _androidBrowser.invokeMethod<void>('resetProxy');
  } catch (_) {
    // The owner may already have been released while the dialog was closing.
  }
}

Future<String> _mobileCookieHeader() async {
  if (Platform.isAndroid) {
    return await _androidBrowser.invokeMethod<String>('getCookies') ?? '';
  }
  final cookies = await WebViewCookieManager().getCookies(
    domain: Uri.parse('${JableClient.origin}/'),
  );
  return cookies
      .where(
        (cookie) =>
            _cookieField(
                  cookie.domain,
                ).replaceFirst(RegExp(r'^\.'), '').toLowerCase() ==
                'jable.tv' &&
            _cookieField(cookie.path) == '/',
      )
      .map(
        (cookie) =>
            '${_cookieField(cookie.name)}=${_cookieField(cookie.value)}',
      )
      .join('; ');
}

Future<void> restoreJableBrowserSession(
  JableClient client,
  int expectedGeneration,
) async {
  int? proxyGeneration;
  try {
    if (Platform.isAndroid) proxyGeneration = await _configureAndroidProxy();
    await _connectJableBrowserSession(
      client,
      expectedGeneration: expectedGeneration,
      androidProxyGeneration: proxyGeneration,
    );
  } catch (_) {
    if (Platform.isAndroid && proxyGeneration != null) {
      await _releaseAndroidProxy(proxyGeneration);
    }
    rethrow;
  }
}

Future<void> _connectJableBrowserSession(
  JableClient client, {
  required int expectedGeneration,
  required int? androidProxyGeneration,
  JableBrowserConnectionLifetime? cancelSignal,
}) async {
  if (!Platform.isWindows &&
      !Platform.isAndroid &&
      ProxyConfig.mode != ProxyMode.system) {
    throw StateError('Jable verification requires the system proxy.');
  }
  final connectionGeneration = ++_jableBrowserConnectionGeneration;
  var proxyGeneration = androidProxyGeneration;
  Webview? desktop;
  WebViewController? mobile;
  OverlayEntry? mobileEntry;
  MissavBrowserAdapter? adapter;
  var disposing = false;

  void ensureCurrent() {
    if (_jableBrowserConnectionGeneration != connectionGeneration ||
        cancelSignal?.isCancelled == true ||
        client.sessionGeneration != expectedGeneration) {
      throw StateError('Jable browser connection was cancelled.');
    }
  }

  final previous = _activeJableBrowser;
  if (previous != null) {
    final previousClient = _activeJableBrowserClient;
    previousClient?.restoreNativeTransport();
    previous.close(force: true);
    try {
      await previous.whenClosed;
    } finally {
      _clearJableBrowserOwner(previous);
    }
  }

  try {
    await client.initialize();
    ensureCurrent();
    if (Platform.isAndroid) {
      if (proxyGeneration == null) {
        proxyGeneration = await _configureAndroidProxy();
      } else if (proxyGeneration != _androidProxyGeneration) {
        throw StateError('Jable browser proxy was replaced.');
      }
      ensureCurrent();
    }

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      if (!await WebviewWindow.isWebviewAvailable()) {
        throw StateError('WebView runtime unavailable.');
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
      final browser = await _createJableDesktopBrowser(hidden: true);
      desktop = browser;
      ensureCurrent();
      await browser.setOnUrlRequestCallback(isJableVerificationUrl);
      await _navigateJableDesktopDocument(
        browser,
        Uri.parse(client.homeUrl),
        cancelSignal?.cancelSignal ?? Completer<void>().future,
        ensureActive: ensureCurrent,
      );

      late final MissavBrowserAdapter browserAdapter;
      browserAdapter = MissavBrowserAdapter.jable(
        runJavaScript: (script) async {
          await browser.evaluateJavaScript(script);
        },
        currentUrl: () async => browser.navigationState.value.url,
        navigateDocument: (uri, cancelled) => _navigateJableDesktopDocument(
          browser,
          uri,
          cancelled,
          ensureActive: ensureCurrent,
        ),
        disposeBrowser: () async {
          disposing = true;
          await _disposeJableDesktopBrowser(browser);
          _clearJableBrowserOwner(browserAdapter);
          if (Platform.isAndroid && proxyGeneration != null) {
            await _releaseAndroidProxy(proxyGeneration);
          }
        },
      );
      adapter = browserAdapter;
      browser.addJavaScriptHandler(
        MissavBrowserAdapter.jableChannelName,
        (message, origin) =>
            browserAdapter.receiveMessage(message, origin: origin),
      );
      unawaited(
        browser.onClose.then((_) {
          if (!disposing) browserAdapter.close(force: true);
        }),
      );
    } else {
      final controller = WebViewController();
      mobile = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      ensureCurrent();
      final overlay = rootNavigatorKey.currentState?.overlay;
      if (overlay == null) throw StateError('Application overlay unavailable.');
      final view = OverlayEntry(
        builder: (_) => Offstage(
          child: SizedBox(
            width: 1,
            height: 1,
            child: WebViewWidget(controller: controller),
          ),
        ),
      );
      overlay.insert(view);
      mobileEntry = view;
      await WidgetsBinding.instance.endOfFrame;
      ensureCurrent();
      await _navigateJableMobileDocument(
        controller,
        Uri.parse(client.homeUrl),
        cancelSignal?.cancelSignal ?? Completer<void>().future,
        ensureActive: ensureCurrent,
      );

      late final MissavBrowserAdapter browserAdapter;
      browserAdapter = MissavBrowserAdapter.jable(
        runJavaScript: controller.runJavaScript,
        currentUrl: controller.currentUrl,
        navigateDocument: (uri, cancelled) => _navigateJableMobileDocument(
          controller,
          uri,
          cancelled,
          ensureActive: ensureCurrent,
        ),
        disposeBrowser: () async {
          disposing = true;
          await _disposeJableMobileBrowser(
            controller,
            view,
            channelName: MissavBrowserAdapter.jableChannelName,
          );
          _clearJableBrowserOwner(browserAdapter);
          if (Platform.isAndroid && proxyGeneration != null) {
            await _releaseAndroidProxy(proxyGeneration);
          }
        },
      );
      adapter = browserAdapter;
      await controller.addJavaScriptChannel(
        MissavBrowserAdapter.jableChannelName,
        onMessageReceived: (message) =>
            browserAdapter.receiveMessage(message.message),
      );
    }

    final connectedAdapter = adapter;
    ensureCurrent();
    client.useVerifiedBrowserTransport(
      connectedAdapter,
      expectedGeneration: expectedGeneration,
      connectionGeneration: connectionGeneration,
    );
    _activeJableBrowser = connectedAdapter;
    _activeJableBrowserClient = client;
    _activeJableAndroidProxyGeneration = proxyGeneration;

    await client.checkBrowserAccess();
    ensureCurrent();
  } catch (_) {
    final active = adapter;
    if (_jableBrowserConnectionGeneration == connectionGeneration &&
        active != null) {
      client.restoreNativeTransportIfCurrent(
        expectedAdapter: active,
        expectedGeneration: expectedGeneration,
        connectionGeneration: connectionGeneration,
      );
    }
    if (active != null) {
      active.close(force: true);
      try {
        await active.whenClosed;
      } catch (_) {}
    } else if (desktop != null) {
      await _disposeJableDesktopBrowser(desktop);
    } else if (mobile != null && mobileEntry != null) {
      await _disposeJableMobileBrowser(
        mobile,
        mobileEntry,
        channelName: MissavBrowserAdapter.jableChannelName,
      );
    }
    if (Platform.isAndroid && proxyGeneration != null) {
      await _releaseAndroidProxy(proxyGeneration);
    }
    rethrow;
  }
}

Future<Webview> _createJableDesktopBrowser({required bool hidden}) async =>
    WebviewWindow.create(
      configuration: CreateConfiguration(
        title: 'Jable',
        windowWidth: 1080,
        windowHeight: 800,
        openHidden: hidden,
        windows: WindowsWebviewOptions(
          userDataFolder: await _desktopProfilePath(),
          denyCameraAndMicrophone: true,
        ),
      ),
    );

Future<String> _navigateJableDesktopDocument(
  Webview browser,
  Uri uri,
  Future<void> cancelled, {
  required void Function() ensureActive,
}) async {
  final completed = Completer<void>();
  void observeNavigation() {
    final state = browser.navigationState.value;
    if (state.isLoading) return;
    final currentUrl = state.url;
    if (currentUrl == null) return;
    if (isJableVerificationUrl(currentUrl)) {
      if (!completed.isCompleted) completed.complete();
    } else if (!completed.isCompleted) {
      completed.completeError(StateError('Jable navigation was blocked.'));
    }
  }

  final errors = browser.onLoadError.listen((error) {
    if (isJableVerificationUrl(error.url) && !completed.isCompleted) {
      completed.completeError(StateError('Jable could not be loaded.'));
    }
  });
  browser.navigationState.addListener(observeNavigation);
  try {
    ensureActive();
    await _awaitJableOperation(
      Future.wait<void>([
        browser.navigationState.value.url == uri.toString()
            ? browser.reload()
            : browser.launch(uri.toString()),
        completed.future.timeout(const Duration(seconds: 30)),
      ], eagerError: true),
      cancelled,
      browser.stop,
    );
    ensureActive();
    final currentUrl = await browser.evaluateJavaScript('location.href');
    if (!isJableVerificationUrl('$currentUrl')) {
      throw VideoSourceException(
        'Jable browser redirected to an unsupported address.',
        sourceKey: 'jable',
        sourceUrl: uri.toString(),
      );
    }
    final markup = await browser.evaluateJavaScript(
      'document.documentElement?.outerHTML ?? ""',
    );
    if (markup is! String) {
      throw VideoSourceException(
        'Jable browser returned an invalid document.',
        sourceKey: 'jable',
        sourceUrl: uri.toString(),
      );
    }
    ensureActive();
    return markup;
  } finally {
    browser.navigationState.removeListener(observeNavigation);
    await errors.cancel();
  }
}

Future<String> _navigateJableMobileDocument(
  WebViewController controller,
  Uri uri,
  Future<void> cancelled, {
  required void Function() ensureActive,
}) async {
  final completed = Completer<void>();
  Object? mainFrameError;
  await controller.setNavigationDelegate(
    NavigationDelegate(
      onNavigationRequest: (request) {
        if (!request.isMainFrame || isJableVerificationUrl(request.url)) {
          return NavigationDecision.navigate;
        }
        final error = VideoSourceException(
          'Jable browser redirected to an unsupported address.',
          sourceKey: 'jable',
          sourceUrl: request.url,
        );
        mainFrameError = error;
        if (!completed.isCompleted) completed.completeError(error);
        return NavigationDecision.prevent;
      },
      onPageFinished: (pageUrl) {
        if (isJableVerificationUrl(pageUrl) && !completed.isCompleted) {
          completed.complete();
        }
      },
      onWebResourceError: (error) {
        if (error.isForMainFrame != false &&
            isJableVerificationUrl(error.url ?? '')) {
          final failure = StateError('Jable could not be loaded.');
          mainFrameError ??= failure;
          if (!completed.isCompleted) completed.completeError(failure);
        }
      },
    ),
  );
  ensureActive();
  await _awaitJableOperation(
    Future.wait<void>([
      controller.loadRequest(uri),
      completed.future.timeout(const Duration(seconds: 30)),
    ], eagerError: true),
    cancelled,
    () => controller.runJavaScript('window.stop();'),
  );
  ensureActive();
  final failure = mainFrameError;
  if (failure != null) throw failure;
  final currentUrl = await controller.currentUrl();
  if (!isJableVerificationUrl(currentUrl ?? '')) {
    throw VideoSourceException(
      'Jable browser redirected to an unsupported address.',
      sourceKey: 'jable',
      sourceUrl: uri.toString(),
    );
  }
  final raw = await controller.runJavaScriptReturningResult(
    'document.documentElement?.outerHTML ?? ""',
  );
  final markup = jableDocumentMarkup(raw, android: Platform.isAndroid);
  ensureActive();
  return markup;
}

Future<T> _awaitJableOperation<T>(
  Future<T> operation,
  Future<void> cancelled,
  Future<void> Function() stop,
) {
  final cancellation = Completer<T>();
  unawaited(
    cancelled.then((_) async {
      try {
        await stop();
      } catch (_) {}
      if (!cancellation.isCompleted) {
        cancellation.completeError(
          const JableVerificationRequiredException(
            sourceUrl: JableClient.origin,
          ),
        );
      }
    }),
  );
  return Future.any<T>([operation, cancellation.future]);
}

Future<void> _disposeJableDesktopBrowser(Webview browser) async {
  try {
    await browser.evaluateJavaScript('''
for (const request of window.__kikoJableRequests?.values() ?? []) request.abort();
window.__kikoJableRequests?.clear();
''');
  } catch (_) {}
  browser.removeJavaScriptHandler(MissavBrowserAdapter.jableChannelName);
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

Future<void> _disposeJableMobileBrowser(
  WebViewController controller,
  OverlayEntry entry, {
  required String channelName,
}) async {
  try {
    await controller.runJavaScript('window.stop();');
  } catch (_) {}
  try {
    await controller.runJavaScript('''
for (const request of window.__kikoJableRequests?.values() ?? []) request.abort();
window.__kikoJableRequests?.clear();
''');
  } catch (_) {}
  try {
    await controller.removeJavaScriptChannel(channelName);
  } catch (_) {}
  try {
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) =>
            !request.isMainFrame || isJableVerificationUrl(request.url)
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ),
    );
  } catch (_) {}
  try {
    await controller.loadRequest(Uri.parse('about:blank'));
  } catch (_) {}
  entry.remove();
  entry.dispose();
}

void _clearJableBrowserOwner(MissavBrowserAdapter adapter) {
  if (!identical(_activeJableBrowser, adapter)) return;
  _activeJableBrowser = null;
  _activeJableBrowserClient = null;
  _activeJableAndroidProxyGeneration = null;
}

Future<bool> verifyJableAccess(
  BuildContext context,
  JableClient client, {
  required String sourceUrl,
  bool requireLogin = false,
}) async {
  if (!isJableVerificationUrl(sourceUrl)) return false;
  int? proxyGeneration;
  var proxyTransferred = false;
  try {
    if (Platform.isAndroid) proxyGeneration = await _configureAndroidProxy();
    if (!context.mounted) return false;
    final verified =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _JableVerification(
            client: client,
            sourceUrl: sourceUrl,
            requireLogin: requireLogin,
            androidProxyGeneration: proxyGeneration,
          ),
        ) ??
        false;
    proxyTransferred =
        verified &&
        Platform.isAndroid &&
        proxyGeneration != null &&
        identical(_activeJableBrowserClient, client) &&
        _activeJableAndroidProxyGeneration == proxyGeneration;
    return verified;
  } catch (_) {
    if (context.mounted) {
      SnackBarUtil.showFromSnackBar(
        context,
        SnackBar(content: Text(S.of(context).videoSourceUnavailable)),
      );
    }
    return false;
  } finally {
    if (Platform.isAndroid && proxyGeneration != null && !proxyTransferred) {
      await _releaseAndroidProxy(proxyGeneration);
    }
  }
}

class _JableVerification extends StatefulWidget {
  const _JableVerification({
    required this.client,
    required this.sourceUrl,
    required this.requireLogin,
    this.androidProxyGeneration,
  });

  final JableClient client;
  final String sourceUrl;
  final bool requireLogin;
  final int? androidProxyGeneration;

  @override
  State<_JableVerification> createState() => _JableVerificationState();
}

class _JableVerificationState extends State<_JableVerification> {
  Webview? _desktop;
  StreamSubscription<WebviewLoadError>? _desktopLoadErrors;
  WebViewController? _mobile;
  bool _starting = true;
  bool _checking = false;
  bool _failed = false;
  bool _proxyUnsupported = false;
  bool _closed = false;
  bool _finished = false;
  late final _browserConnectionCancellation = JableBrowserConnectionLifetime(
    widget.client,
  );

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  bool get _isCurrent => mounted && !_closed && !_finished;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
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
          throw StateError('WebView runtime unavailable.');
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
        final browser = await WebviewWindow.create(
          configuration: CreateConfiguration(
            title: 'Jable',
            windowWidth: 1080,
            windowHeight: 800,
            openHidden: false,
            brightness: mounted ? Theme.of(context).brightness : null,
            windows: WindowsWebviewOptions(
              userDataFolder: await _desktopProfilePath(),
              denyCameraAndMicrophone: true,
            ),
          ),
        );
        if (!mounted) {
          await browser.close();
          return;
        }
        _desktop = browser;
        await browser.setOnUrlRequestCallback(isJableVerificationUrl);
        _desktopLoadErrors = browser.onLoadError.listen((_) {
          if (mounted) setState(() => _failed = true);
        });
        unawaited(
          browser.onClose.then((_) {
            _closed = true;
            unawaited(_browserConnectionCancellation.cancel());
            if (!_checking) _finish(false);
          }),
        );
        await browser.launch(widget.sourceUrl);
      } else {
        final controller = WebViewController();
        _mobile = controller;
        await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
        await controller.setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) =>
                !request.isMainFrame || isJableVerificationUrl(request.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
            onWebResourceError: (error) {
              if (error.isForMainFrame == true && mounted) {
                setState(() => _failed = true);
              }
            },
          ),
        );
        await controller.loadRequest(Uri.parse(widget.sourceUrl));
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
    if (_checking || _closed) return;
    final client = widget.client;
    final requireLogin = widget.requireLogin;
    setState(() {
      _checking = true;
      _failed = false;
    });
    try {
      await client.initialize();
      if (!_isCurrent) return;
      final browser = _desktop;
      final mobile = _mobile;
      if (requireLogin) {
        final uri = Uri.parse(JableAccount.favoritesUrl);
        final cancelled = _browserConnectionCancellation.cancelSignal;
        void ensureOpen() {
          if (!_isCurrent) throw StateError('Jable login was cancelled.');
        }

        final markup = browser != null
            ? await _navigateJableDesktopDocument(
                browser,
                uri,
                cancelled,
                ensureActive: ensureOpen,
              )
            : await _navigateJableMobileDocument(
                mobile!,
                uri,
                cancelled,
                ensureActive: ensureOpen,
              );
        ensureOpen();
        if (!JableAccount.hasFavoritesList(html_parser.parse(markup))) {
          if (browser != null) {
            await browser.launch(widget.sourceUrl);
          } else {
            await mobile!.loadRequest(Uri.parse(widget.sourceUrl));
          }
          throw StateError('Jable sign-in is required.');
        }
      }
      final cookies = browser != null
          ? jableVerificationCookieHeader(await browser.getAllCookies())
          : await _mobileCookieHeader();
      if (!_isCurrent) return;
      final rawAgent = browser != null
          ? await browser.evaluateJavaScript('navigator.userAgent')
          : await mobile?.getUserAgent();
      if (!_isCurrent) return;
      if (cookies.isEmpty || rawAgent is! String || rawAgent.trim().isEmpty) {
        throw StateError('Jable browser session is unavailable.');
      }
      final generation = client.sessionGeneration;
      await client.importVerifiedSession(
        cookieHeader: cookies,
        userAgent: rawAgent,
        expectedGeneration: generation,
      );
      final importedGeneration = client.sessionGeneration;
      _browserConnectionCancellation.sessionImported(importedGeneration);
      if (!_isCurrent) {
        await _browserConnectionCancellation.discardImportedSession();
        return;
      }
      await _connectJableBrowserSession(
        client,
        expectedGeneration: importedGeneration,
        androidProxyGeneration: widget.androidProxyGeneration,
        cancelSignal: _browserConnectionCancellation,
      );
      if (requireLogin && !await client.account.checkLogin()) {
        throw StateError('Jable sign-in could not be confirmed.');
      }
      if (!_isCurrent) {
        await _browserConnectionCancellation.discardImportedSession();
        return;
      }
      _finish(true);
    } catch (_) {
      await _browserConnectionCancellation.discardImportedSession();
      if (_isCurrent) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _checking = false);
        if (_closed && !_finished) _finish(false);
      }
    }
  }

  void _finish(bool verified) {
    if (!mounted || _finished || (verified && _closed)) return;
    _finished = true;
    if (verified) {
      _browserConnectionCancellation.handoff();
    } else {
      unawaited(_browserConnectionCancellation.cancel());
    }
    Navigator.of(context).pop(verified);
  }

  Future<void> _closeDesktop() async {
    final browser = _desktop;
    if (browser != null && !_closed) {
      try {
        await browser.close();
        await browser.onClose;
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    unawaited(_browserConnectionCancellation.cancel());
    unawaited(_desktopLoadErrors?.cancel());
    unawaited(_closeDesktop());
    final mobile = _mobile;
    if (mobile != null) unawaited(mobile.loadRequest(Uri.parse('about:blank')));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return PopScope<bool>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_finished) {
          _finished = true;
          unawaited(_browserConnectionCancellation.cancel());
        }
      },
      child: AlertDialog(
        title: Text(
          widget.requireLogin ? s.videoJableAccount : s.videoVerifyAccess,
        ),
        content: SizedBox(
          width: _isDesktop ? 420 : 720,
          height: _isDesktop ? null : MediaQuery.sizeOf(context).height * .65,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.requireLogin
                    ? s.videoLoginHelp
                    : s.videoVerificationHelp,
              ),
              if (_proxyUnsupported) ...[
                const SizedBox(height: 12),
                Text(s.videoVerificationSystemProxyRequired),
              ],
              if (_starting) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
              if (_failed) ...[
                const SizedBox(height: 12),
                Text(
                  widget.requireLogin
                      ? s.loginFailed
                      : s.videoVerificationFailed,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (!_isDesktop && _mobile != null) ...[
                const SizedBox(height: 12),
                Expanded(child: WebViewWidget(controller: _mobile!)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _finish(false);
              unawaited(_closeDesktop());
            },
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: _starting || _checking || _closed || _proxyUnsupported
                ? null
                : _check,
            child: _checking
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    widget.requireLogin
                        ? s.videoLoginComplete
                        : s.videoVerificationContinue,
                  ),
          ),
        ],
      ),
    );
  }
}

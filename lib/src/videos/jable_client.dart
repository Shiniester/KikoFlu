import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../services/proxy_config.dart';
import 'missav_browser_adapter.dart';
import 'video_models.dart';
import 'video_source_client.dart';

part 'jable_account.dart';

class JableClient implements VideoSourceClient {
  JableClient({
    Dio? dio,
    FlutterSecureStorage? secureStorage,
    this.restoreSavedSession,
  }) : _ownsDio = dio == null,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 20),
               sendTimeout: const Duration(seconds: 10),
             ),
           ),
       _secureStorage = secureStorage ?? const FlutterSecureStorage() {
    if (dio == null) {
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () =>
            HttpClient()..findProxy = ProxyConfig.findProxyFor,
      );
    }
    _nativeAdapter = _dio.httpClientAdapter;
  }

  static const origin = 'https://jable.tv';
  static const _sessionKey = 'jable_verified_session';
  static const _defaultUserAgent = 'Mozilla/5.0';

  late final JableAccount account = JableAccount._(this);

  final Dio _dio;
  final FlutterSecureStorage _secureStorage;
  final Future<void> Function(JableClient client, int expectedGeneration)?
  restoreSavedSession;
  final bool _ownsDio;
  String? _cookie;
  String _userAgent = _defaultUserAgent;
  String? _locale;
  late final HttpClientAdapter _nativeAdapter;
  HttpClientAdapter? _browserAdapter;
  int? _browserConnectionGeneration;
  CancelToken _sessionCancelToken = CancelToken();
  Completer<void>? _sessionRestoration;
  int _generation = 0;
  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _initializing;
  Future<void> _sessionWriteTail = Future<void>.value();

  @override
  String get sourceKey => 'jable';

  int get sessionGeneration => _generation;

  @override
  String get homeUrl => origin;

  @override
  String get defaultCatalogUrl => homeUrl;

  @override
  bool setLocale(String languageTag) {
    final language = languageTag
        .replaceAll('_', '-')
        .toLowerCase()
        .split('-')
        .first;
    final locale = switch (language) {
      'ja' => 'jp',
      'en' => 'en',
      'zh' => 'zh',
      _ => null,
    };
    if (locale == null || locale == _locale) return false;
    _locale = locale;
    return true;
  }

  @override
  List<VideoSearchFilterKind> get searchFilterKinds => const [
    VideoSearchFilterKind.genre,
    VideoSearchFilterKind.actor,
  ];

  @override
  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initializing ??= _loadSession().whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _loadSession() async {
    final generation = _generation;
    final saved = await _secureStorage.read(key: _sessionKey);
    if (_disposed || generation != _generation) return;
    if (saved != null) {
      try {
        final decoded = jsonDecode(saved);
        if (decoded is Map &&
            decoded['cookie'] is String &&
            decoded['userAgent'] is String) {
          _cookie = (decoded['cookie'] as String).trim();
          _userAgent = (decoded['userAgent'] as String).trim();
        }
      } on FormatException {
        // Ignore a malformed source session and let the user verify again.
      }
    }
    _initialized = true;
  }

  Future<void> _prepareOnlineAccess() async {
    await initialize();
    final browser = _browserAdapter;
    if (browser is MissavBrowserAdapter && browser.isClosed) {
      restoreNativeTransport();
    }
    if (_browserAdapter != null) return;
    final pending = _sessionRestoration;
    if (pending != null) {
      await pending.future;
      return;
    }
    if (_cookie?.isNotEmpty != true) return;
    final restorer = restoreSavedSession;
    if (restorer == null) return;

    final generation = _generation;
    final restoration = Completer<void>();
    _sessionRestoration = restoration;
    unawaited(_runSessionRestoration(restorer, generation, restoration));
    await restoration.future;
  }

  Future<void> _runSessionRestoration(
    Future<void> Function(JableClient client, int expectedGeneration) restorer,
    int generation,
    Completer<void> restoration,
  ) async {
    try {
      await restorer(this, generation);
      if (_disposed || generation != _generation || _browserAdapter == null) {
        throw VideoSourceException(
          'Jable browser session could not be restored.',
          sourceKey: sourceKey,
        );
      }
      restoration.complete();
    } catch (error, stackTrace) {
      restoration.completeError(error, stackTrace);
    } finally {
      if (identical(_sessionRestoration, restoration)) {
        _sessionRestoration = null;
      }
    }
  }

  void useVerifiedBrowserTransport(
    HttpClientAdapter adapter, {
    required int expectedGeneration,
    int? connectionGeneration,
  }) {
    if (_disposed) return;
    if (expectedGeneration != _generation) {
      throw StateError('Jable browser session changed during verification.');
    }
    if (identical(adapter, _browserAdapter)) {
      _browserConnectionGeneration = connectionGeneration;
      return;
    }
    final previous = _browserAdapter;
    _browserAdapter = adapter;
    _browserConnectionGeneration = connectionGeneration;
    _dio.httpClientAdapter = adapter;
    if (previous != null && !identical(previous, _nativeAdapter)) {
      previous.close(force: true);
    }
  }

  void restoreNativeTransport() {
    if (_disposed) return;
    final browser = _browserAdapter;
    _browserAdapter = null;
    _browserConnectionGeneration = null;
    _dio.httpClientAdapter = _nativeAdapter;
    if (browser != null && !identical(browser, _nativeAdapter)) {
      browser.close(force: true);
    }
  }

  bool restoreNativeTransportIfCurrent({
    required HttpClientAdapter expectedAdapter,
    required int expectedGeneration,
    required int connectionGeneration,
  }) {
    if (_generation != expectedGeneration ||
        !identical(_browserAdapter, expectedAdapter) ||
        _browserConnectionGeneration != connectionGeneration) {
      return false;
    }
    restoreNativeTransport();
    return true;
  }

  Future<void> importVerifiedSession({
    required String cookieHeader,
    required String userAgent,
    int? expectedGeneration,
  }) async {
    await initialize();
    if (expectedGeneration != null && expectedGeneration != _generation) {
      throw StateError('Jable browser session changed during verification.');
    }
    final cookie = cookieHeader.trim();
    final agent = userAgent.trim();
    if (cookie.isEmpty || agent.isEmpty) {
      throw StateError('Jable browser session is unavailable.');
    }
    final generation = _advanceSessionGeneration();
    _cookie = cookie;
    _userAgent = agent;
    await _queueSessionWrite(
      () => _secureStorage.write(
        key: _sessionKey,
        value: jsonEncode({'cookie': cookie, 'userAgent': agent}),
      ),
    );
    if (_disposed || generation != _generation) {
      throw StateError('Jable browser session changed during verification.');
    }
  }

  Future<void> clearSession({int? expectedGeneration}) async {
    if (expectedGeneration != null && expectedGeneration != _generation) return;
    restoreNativeTransport();
    final generation = _advanceSessionGeneration();
    _cookie = null;
    _userAgent = _defaultUserAgent;
    await _queueSessionWrite(() => _secureStorage.delete(key: _sessionKey));
    if (!_disposed && generation != _generation) return;
  }

  Future<void> checkBrowserAccess() async {
    await browse(homeUrl);
  }

  int _advanceSessionGeneration() {
    final previous = _sessionCancelToken;
    final generation = ++_generation;
    account._sessionChanged();
    _sessionCancelToken = CancelToken();
    if (!previous.isCancelled) previous.cancel('Jable session changed');
    return generation;
  }

  Future<void> _queueSessionWrite(Future<void> Function() write) {
    final pending = _sessionWriteTail.then((_) => write());
    _sessionWriteTail = pending.catchError((_) {});
    return pending;
  }

  @override
  Future<VideoCatalogPage> browse(
    String url, {
    CancelToken? cancelToken,
    void Function(VideoCatalogPage page)? onParsed,
  }) async {
    final uri = _sourceUri(Uri.parse(url));
    await _prepareOnlineAccess();
    if (JableAccount.isFavoritesUri(uri) && !account._hasSession) {
      throw const JableLoginRequiredException(
        sourceUrl: JableAccount.favoritesUrl,
      );
    }
    final generation = _generation;
    final document = await _loadDocument(uri, cancelToken: cancelToken);
    _ensureGeneration(generation, uri);
    if (JableAccount.isFavoritesUri(uri)) {
      final page = account._parseFavoritesPage(document, uri);
      if (cancelToken?.cancelError case final error?) throw error;
      onParsed?.call(page);
      return page;
    }
    final currentPage = _currentPage(document, uri);
    final parsedPage = VideoCatalogPage(
      title: _pageTitle(document, uri),
      url: uri.toString(),
      videos: _parseVideos(document, uri),
      links: _parseDirectoryLinks(document, uri),
      navigation: _parseNavigation(document, uri),
      nextUrl: _paginationUrl(document, uri, next: true),
      previousUrl: _paginationUrl(document, uri, next: false),
      currentPage: currentPage,
      jumpMaxPage: _jumpMaxPage(document, uri),
      pageUrlBuilder: _pageUrlBuilder(document, uri),
    );
    if (cancelToken?.cancelError case final error?) throw error;
    onParsed?.call(parsedPage);
    return parsedPage;
  }

  @override
  Future<VideoCatalogPage> search(String query) {
    final value = query.trim();
    if (value.isEmpty) throw ArgumentError.value(query, 'query');
    return browse('$origin/search/${Uri.encodeComponent(value)}/');
  }

  @override
  Future<VideoCatalogPage> searchFilterOptions(
    VideoSearchFilterKind kind, {
    String? pageUrl,
  }) async {
    final url = switch (kind) {
      VideoSearchFilterKind.genre => '$origin/categories/',
      VideoSearchFilterKind.actor => '$origin/models/',
      _ => throw ArgumentError.value(kind, 'kind'),
    };
    final page = await browse(pageUrl ?? url);
    return VideoCatalogPage(
      title: page.title,
      url: page.url,
      links: page.links
          .where(
            (link) => switch (kind) {
              VideoSearchFilterKind.genre =>
                link.kind == VideoLinkKind.category ||
                    link.kind == VideoLinkKind.tag,
              VideoSearchFilterKind.actor => link.kind == VideoLinkKind.actor,
              _ => false,
            },
          )
          .toList(growable: false),
      navigation: page.navigation,
      nextUrl: page.nextUrl,
      previousUrl: page.previousUrl,
      currentPage: page.currentPage,
      jumpMaxPage: page.jumpMaxPage,
      pageUrlBuilder: page.pageUrlBuilder,
    );
  }

  @override
  Future<List<VideoItem>> searchWithFilters(
    String query,
    List<VideoLink> filters, {
    bool Function()? isCurrent,
  }) async {
    await _prepareOnlineAccess();
    final generation = _generation;
    final locale = _locale;
    final keyword = query.trim();
    final urls = <String>{
      if (keyword.isNotEmpty) '$origin/search/${Uri.encodeComponent(keyword)}/',
      for (final filter in filters) _filterCatalogUrl(filter.url),
    };
    return intersectVideoCatalogs(
      urls: urls,
      browse: browse,
      isCurrent: () =>
          !_disposed &&
          generation == _generation &&
          locale == _locale &&
          (isCurrent?.call() ?? true),
    );
  }

  @override
  Future<VideoDetails> details(
    VideoItem item, {
    FutureOr<void> Function(VideoDetails)? onReady,
    bool includeAccountState = true,
  }) async {
    final uri = _sourceUri(Uri.parse(item.pageUrl));
    await _prepareOnlineAccess();
    final generation = _generation;
    final document = await _loadDocument(uri);
    _ensureGeneration(generation, uri);
    final marker = includeAccountState
        ? account._favoriteControl(document)
        : null;
    final title =
        _metaContent(document, 'og:title') ??
        document.querySelector('h1')?.text.trim();
    final cover = _metaContent(document, 'og:image');
    final date = document
        .querySelector('.video-info .info-header .inactive-color')
        ?.text
        .trim();
    final actors = _parseNamedLinks(document, uri, 'models');
    final tags = [
      ..._parseNamedLinks(document, uri, 'categories'),
      ..._parseNamedLinks(document, uri, 'tags'),
    ];
    final video = VideoItem(
      id: item.id,
      sourceKey: sourceKey,
      title: title?.isNotEmpty == true ? title! : item.title,
      pageUrl: uri.toString(),
      cover: cover == null || cover.isEmpty
          ? item.cover
          : _absoluteUrl(uri, cover),
      durationSeconds: item.durationSeconds,
      releaseDate: date?.isNotEmpty == true ? date : item.releaseDate,
      actors: _mergeLinks(actors, item.actors),
      tags: _mergeLinks(tags, item.tags),
      makers: item.makers,
      labels: item.labels,
      series: item.series,
      directors: item.directors,
      hasSubtitles: item.hasSubtitles,
      isUncensored: item.isUncensored,
    );
    final streamUrl = _parseHlsUrl(document, uri);
    if (streamUrl == null) {
      throw VideoSourceException(
        'Jable did not provide a playable video stream.',
        sourceKey: sourceKey,
        sourceUrl: uri.toString(),
      );
    }
    final details = VideoDetails(
      video: video,
      description: _metaContent(document, 'description') ?? '',
      related: _parseVideos(document, uri),
      sourceId: marker?.id,
      isFavorite: marker?.selected,
      streams: [
        VideoStream(
          label: 'HLS',
          url: streamUrl,
          headers: {'Referer': uri.toString()},
          isHls: true,
        ),
      ],
    );
    await onReady?.call(details);
    return details;
  }

  Future<Document> _loadDocument(Uri uri, {CancelToken? cancelToken}) async {
    final generation = _generation;
    final documentUri = _documentUri(uri);
    final browser = _browserAdapter;
    if (browser is MissavBrowserAdapter) {
      final String body;
      try {
        body = await browser.loadDocument(
          documentUri,
          cancelToken: cancelToken ?? _sessionCancelToken,
        );
      } on DioException catch (error) {
        _ensureGeneration(generation, documentUri);
        if (error.error is VideoSourceException) throw error.error!;
        if (error.type == DioExceptionType.cancel) rethrow;
        throw VideoSourceException(
          'Jable browser navigation failed (${error.type.name}).',
          sourceKey: sourceKey,
          sourceUrl: documentUri.toString(),
          cause: error,
        );
      }
      _ensureGeneration(generation, documentUri);
      final document = html_parser.parse(body);
      if (_looksLikeChallenge(body)) {
        throw JableVerificationRequiredException(
          sourceUrl: documentUri.toString(),
        );
      }
      return document;
    }

    var current = documentUri;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final response = await _dio.getUri<String>(
        current,
        cancelToken: cancelToken ?? _sessionCancelToken,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {
            'Accept': 'text/html,application/xhtml+xml',
            'User-Agent': _userAgent,
            if (_cookie?.isNotEmpty == true && current.host == 'jable.tv')
              'Cookie': _cookie,
          },
        ),
      );
      final status = response.statusCode ?? 0;
      final body = response.data ?? '';
      if (status == HttpStatus.forbidden || _looksLikeChallenge(body)) {
        throw JableVerificationRequiredException(sourceUrl: current.toString());
      }
      if (status >= 300 && status < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) break;
        current = _sourceUri(current.resolve(location));
        continue;
      }
      if (status < 200 || status >= 300) {
        throw VideoSourceException(
          'Jable returned HTTP $status.',
          sourceKey: sourceKey,
          sourceUrl: current.toString(),
        );
      }
      if (body.trim().isEmpty) {
        throw VideoSourceException(
          'Jable returned an empty page.',
          sourceKey: sourceKey,
          sourceUrl: current.toString(),
        );
      }
      return html_parser.parse(body);
    }
    throw VideoSourceException(
      'Jable redirected to an unsupported page.',
      sourceKey: sourceKey,
      sourceUrl: current.toString(),
    );
  }

  Uri _documentUri(Uri uri) => _locale == null
      ? uri
      : uri.replace(
          queryParameters: {...uri.queryParameters, 'lang': _locale!},
        );

  bool _looksLikeChallenge(String html) {
    final value = html.toLowerCase();
    final title =
        html_parser.parse(html).querySelector('title')?.text.toLowerCase() ??
        '';
    return value.contains('cf-chl-') ||
        value.contains('cf_chl_') ||
        value.contains('/cdn-cgi/challenge-platform') ||
        value.contains('challenge-form') ||
        title.startsWith('just a moment') ||
        title.startsWith('attention required') ||
        (value.contains('cloudflare') && value.contains('challenge'));
  }

  List<VideoItem> _parseVideos(Document document, Uri base) {
    final videos = <VideoItem>[];
    final seen = <String>{};
    final listedCards = document.querySelectorAll(
      '[id^="list_videos_"] .video-img-box',
    );
    final cards = listedCards.isEmpty
        ? document.querySelectorAll('div.video-img-box')
        : listedCards;
    for (final card in cards) {
      final anchor = card.querySelector('a[href*="/videos/"]');
      final pageUrl = _directoryUrl(base, anchor?.attributes['href']);
      if (pageUrl == null) continue;
      final id = _videoId(pageUrl);
      if (id == null || !seen.add(id)) continue;
      final title =
          card.querySelector('.detail .title')?.text.trim() ??
          card.querySelector('div.detail h6')?.text.trim() ??
          card.querySelector('.title')?.text.trim() ??
          card.querySelector('h6')?.text.trim() ??
          '';
      if (title.isEmpty) continue;
      final image = card.querySelector('img');
      final cover =
          image?.attributes['data-src'] ??
          image?.attributes['data-original'] ??
          image?.attributes['src'] ??
          '';
      videos.add(
        VideoItem(
          id: id,
          sourceKey: sourceKey,
          title: title,
          pageUrl: pageUrl,
          cover: cover.isEmpty ? '' : _absoluteUrl(base, cover),
          durationSeconds: _durationSeconds(
            card.querySelector('.absolute-bottom-right')?.text,
          ),
        ),
      );
    }
    return videos;
  }

  List<VideoLink> _parseDirectoryLinks(Document document, Uri base) {
    final sourcePath = _segments(base);
    final prefix = sourcePath.firstOrNull;
    final links = <VideoLink>[];
    final seen = <String>{};

    if (prefix == 'categories' && sourcePath.length == 1) {
      final directoryCards = document.querySelectorAll(
        '#list_categories_video_categories_list .video-img-box, '
        '#list_categories_video_categories_list .img-box',
      );
      final cards = directoryCards.isEmpty
          ? document.querySelectorAll('div.video-img-box, div.img-box')
          : directoryCards;
      for (final card in cards) {
        final anchor = card.querySelector('a[href]');
        final link = _directoryCardLink(base, card, anchor, const {
          'categories',
        }, VideoLinkKind.category);
        if (link != null && seen.add(link.url)) links.add(link);
      }

      for (final title
          in document.querySelectorAll('.app-nav .title-box').skip(1)) {
        final row = title.nextElementSibling;
        for (final anchor in row?.querySelectorAll('a.tag[href]') ?? const []) {
          final link = _directoryCardLink(base, null, anchor, const {
            'tags',
          }, VideoLinkKind.tag);
          if (link != null && seen.add(link.url)) links.add(link);
        }
      }
    }

    if (prefix == 'models' && _isModelDirectory(document, base)) {
      for (final card in _modelDirectoryCards(document, base)) {
        final anchor = card.attributes.containsKey('href')
            ? card
            : card.querySelector('a[href]');
        final link = _directoryCardLink(base, card, anchor, const {
          'models',
        }, VideoLinkKind.actor);
        if (link != null && seen.add(link.url)) links.add(link);
      }
    }
    return links;
  }

  bool _isModelDirectory(Document document, Uri base) {
    final segments = _segments(base);
    if (segments.length == 1) return true;
    final pathPage = segments.length == 2 ? int.tryParse(segments.last) : null;
    return pathPage != null &&
        _activePage(document) == pathPage &&
        document.querySelector('[id^="list_videos_"] .video-img-box') == null &&
        _modelDirectoryCards(document, base).isNotEmpty;
  }

  List<Element> _modelDirectoryCards(Document document, Uri base) {
    final cards = document.querySelectorAll(
      'div.video-img-box, div.model-box, div.model-card',
    );
    final matches = <Element>[];
    for (final card in cards) {
      final anchor = card.querySelector('a[href]');
      final url = _directoryUrl(base, anchor?.attributes['href']);
      if (url == null || !_isModelProfileUrl(url)) continue;
      matches.add(card);
    }
    if (matches.isNotEmpty) return matches;

    for (final anchor in document.querySelectorAll('#site-content a[href]')) {
      final url = _directoryUrl(base, anchor.attributes['href']);
      if (url == null ||
          !_isModelProfileUrl(url) ||
          _hasAncestorClass(anchor, 'pagination') ||
          _hasAncestorClass(anchor, 'sidebar') ||
          _hasAncestorClass(anchor, 'video-info')) {
        continue;
      }
      matches.add(anchor);
    }
    return matches;
  }

  bool _isModelProfileUrl(String url) {
    final segments = _segments(Uri.parse(url));
    return segments.length == 2 && segments.first == 'models';
  }

  bool _hasAncestorClass(Element element, String className) {
    var parent = element.parent;
    while (parent != null) {
      if (parent.classes.contains(className)) return true;
      parent = parent.parent;
    }
    return false;
  }

  bool _isInPagination(Element element) =>
      element.classes.contains('pagination') ||
      _hasAncestorClass(element, 'pagination');

  List<VideoLink> _parseNamedLinks(Document document, Uri base, String prefix) {
    final links = <VideoLink>[];
    final seen = <String>{};
    final selectors = switch (prefix) {
      'models' => '.video-info .info-header .models .model[href]',
      'categories' => '.video-info .tags .cat[href]',
      'tags' => '.video-info .tags a:not(.cat)[href]',
      _ => '',
    };
    if (selectors.isEmpty) return links;
    for (final anchor in document.querySelectorAll(selectors)) {
      final url = _directoryUrl(base, anchor.attributes['href']);
      if (url == null) continue;
      final segments = _segments(Uri.parse(url));
      final expectedRoot = prefix == 'tags' ? 'tags' : prefix;
      if (segments.length != 2 ||
          segments.first != expectedRoot ||
          !seen.add(url)) {
        continue;
      }
      final label = prefix == 'models'
          ? anchor
                    .querySelector('.rounded-circle')
                    ?.attributes['data-original-title']
                    ?.trim() ??
                anchor.text.trim()
          : anchor.text.trim();
      if (label.isEmpty) continue;
      links.add(
        VideoLink(
          label: label,
          url: url,
          kind: switch (prefix) {
            'models' => VideoLinkKind.actor,
            'categories' => VideoLinkKind.category,
            _ => VideoLinkKind.tag,
          },
        ),
      );
    }
    return links;
  }

  VideoLink? _directoryCardLink(
    Uri base,
    Element? card,
    Element? anchor,
    Set<String> roots,
    VideoLinkKind kind,
  ) {
    if (anchor == null) return null;
    final url = _directoryUrl(base, anchor.attributes['href']);
    if (url == null) return null;
    final segments = _segments(Uri.parse(url));
    if (segments.length != 2 || !roots.contains(segments.first)) return null;
    final label =
        card?.querySelector('h4, h5, h6, .title, .name')?.text.trim() ??
        anchor.querySelector('h4, h5, h6, .title, .name')?.text.trim() ??
        anchor.text.trim();
    if (label.isEmpty) return null;
    final image = card?.querySelector('img') ?? anchor.querySelector('img');
    final cover =
        image?.attributes['data-src'] ??
        image?.attributes['data-original'] ??
        image?.attributes['src'] ??
        '';
    return VideoLink(
      label: label,
      url: url,
      cover: cover.isEmpty ? '' : _absoluteUrl(base, cover),
      kind: kind,
    );
  }

  List<VideoLink> _mergeLinks(
    Iterable<VideoLink> parsed,
    Iterable<VideoLink> known,
  ) {
    final merged = <VideoLink>[];
    final seen = <String>{};
    for (final link in [...parsed, ...known]) {
      if (seen.add(link.url)) merged.add(link);
    }
    return merged;
  }

  int? _durationSeconds(String? value) {
    final parts = value?.trim().split(':');
    if (parts == null || parts.length < 2 || parts.length > 3) return null;
    final numbers = parts.map(int.tryParse).toList();
    if (numbers.any((part) => part == null || part < 0)) return null;
    if (numbers.skip(1).any((part) => part! > 59)) return null;
    return switch (numbers.length) {
      2 => numbers[0]! * 60 + numbers[1]!,
      3 => numbers[0]! * 3600 + numbers[1]! * 60 + numbers[2]!,
      _ => null,
    };
  }

  String? _parseHlsUrl(Document document, Uri base) {
    final pattern = RegExp(
      r'''\bhlsUrl\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    );
    for (final script in document.querySelectorAll('script')) {
      final match = pattern.firstMatch(script.text);
      if (match == null) continue;
      final value = match
          .group(1)!
          .replaceAll(r'\/', '/')
          .replaceAll(r'\u0026', '&')
          .replaceAll('&amp;', '&');
      final uri = Uri.tryParse(value);
      if (uri != null &&
          uri.scheme == 'https' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty) {
        return uri.toString();
      }
      final resolved = Uri.tryParse(_absoluteUrl(base, value));
      if (resolved != null &&
          resolved.scheme == 'https' &&
          resolved.host.isNotEmpty &&
          resolved.userInfo.isEmpty) {
        return resolved.toString();
      }
    }
    return null;
  }

  String _pageTitle(Document document, Uri uri) =>
      document.querySelector('h1')?.text.trim().takeIfNotEmpty ??
      document.querySelector('title')?.text.trim().takeIfNotEmpty ??
      uri.pathSegments.lastOrNull ??
      'Jable';

  String? _metaContent(Document document, String selectorValue) {
    final selector = selectorValue == 'og:title' || selectorValue == 'og:image'
        ? 'meta[property="$selectorValue"]'
        : 'meta[name="$selectorValue"]';
    return document.querySelector(selector)?.attributes['content']?.trim();
  }

  List<VideoLink> _parseNavigation(Document document, Uri base) {
    final navigation = <VideoLink>[];
    final seen = <String>{};
    for (final element in document.querySelectorAll('[data-parameters]')) {
      if (_isInPagination(element)) continue;
      final sortBy = _sortByParameter(element.attributes['data-parameters']);
      if (sortBy == null) continue;
      final label = element.text.trim();
      if (label.isEmpty) continue;
      final href = _directoryUrl(base, element.attributes['href']);
      final target = href == null ? null : Uri.parse(href);
      final url =
          target != null &&
              _sameCatalog(document, base, target) &&
              target.queryParameters['sort_by'] == sortBy
          ? target.toString()
          : _sortByUrl(document, base, sortBy);
      if (seen.add(url)) {
        navigation.add(
          VideoLink(label: label, url: url, kind: VideoLinkKind.navigation),
        );
      }
    }

    for (final anchor in document.querySelectorAll(
      '.filter a[href], .filters a[href], .filter-item[href], '
      '.filter-item a[href], .sort a[href], .sorting a[href]',
    )) {
      if (_isInPagination(anchor)) continue;
      if (_sortByParameter(anchor.attributes['data-parameters']) != null) {
        continue;
      }
      final href = _directoryUrl(base, anchor.attributes['href']);
      if (href == null) continue;
      final target = Uri.parse(href);
      if (!_sameCatalog(document, base, target)) continue;
      final label = anchor.text.trim();
      if (label.isEmpty || !seen.add(href)) continue;
      navigation.add(
        VideoLink(label: label, url: href, kind: VideoLinkKind.navigation),
      );
    }
    return navigation;
  }

  String? _sortByParameter(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'''["']?sort_by["']?\s*[:=]\s*["']?([a-zA-Z0-9_-]+)''',
    ).firstMatch(value);
    return match?.group(1);
  }

  String _sortByUrl(Document document, Uri base, String sortBy) {
    final uri = _catalogUri(document, base);
    return uri
        .replace(queryParameters: {...uri.queryParameters, 'sort_by': sortBy})
        .toString();
  }

  String _filterCatalogUrl(String value) {
    final uri = _sourceUri(Uri.parse(value));
    final parameters = Map<String, String>.of(uri.queryParameters)
      ..remove('page')
      ..remove('from');
    if (parameters.isEmpty) {
      return uri.queryParameters.isEmpty
          ? uri.toString()
          : _replacePathAndQuery(uri, uri.pathSegments, parameters).toString();
    }
    return uri.replace(queryParameters: parameters).toString();
  }

  int? _activePage(Document document) {
    final active = document.querySelector(
      '.pagination .page-item.active .page-link, '
      '.pagination .page-link.active, '
      '.pagination .active a, .pagination .active',
    );
    return int.tryParse(active?.text.trim() ?? '');
  }

  int _currentPage(Document document, Uri uri) {
    final active = _activePage(document);
    if (active != null) return active;
    final from = int.tryParse(uri.queryParameters['from'] ?? '');
    if (from != null && from > 0) return from;
    final page = int.tryParse(uri.queryParameters['page'] ?? '');
    if (page != null && page > 0) return page;
    final pathPage = _pageNumber(uri);
    if (pathPage != null) return pathPage;
    return 1;
  }

  String? _paginationUrl(Document document, Uri base, {required bool next}) {
    final currentPage = _currentPage(document, base);
    final targetPage = currentPage + (next ? 1 : -1);
    if (targetPage < 1) return null;
    for (final anchor in _paginationAnchors(document)) {
      final url = _directoryUrl(base, anchor.attributes['href']);
      if (url == null) continue;
      final target = Uri.parse(url);
      if (!_sameCatalog(document, base, target)) continue;
      if (_paginationTargetPage(document, base, anchor, target) == targetPage) {
        return _carryCatalogQuery(base, target);
      }
    }
    return null;
  }

  List<Element> _paginationAnchors(Document document) => document
      .querySelectorAll(
        '.pagination a[href], a[rel="next"][href], a[rel="prev"][href]',
      )
      .toList(growable: false);

  int? _paginationTargetPage(
    Document document,
    Uri base,
    Element anchor,
    Uri target,
  ) {
    final label = int.tryParse(anchor.text.trim());
    if (label != null) return label;
    final page = int.tryParse(target.queryParameters['page'] ?? '');
    if (page != null && page > 0) return page;
    final from = int.tryParse(target.queryParameters['from'] ?? '');
    if (from != null && from > 0) return from;
    final targetRoot = _catalogPathSegments(document, base);
    final targetSegments = _segments(target);
    if (_sameSegments(targetSegments, targetRoot)) return 1;
    if (targetSegments.length == targetRoot.length + 1 &&
        _sameSegments(targetSegments.take(targetRoot.length), targetRoot)) {
      return int.tryParse(targetSegments.last);
    }
    return _pageNumber(target);
  }

  int? _jumpMaxPage(Document document, Uri base) {
    var maximum = 1;
    for (final anchor in _paginationAnchors(document)) {
      final url = _directoryUrl(base, anchor.attributes['href']);
      if (url == null) continue;
      final target = Uri.parse(url);
      if (!_sameCatalog(document, base, target)) continue;
      final page = _paginationTargetPage(document, base, anchor, target);
      if (page != null && page > maximum) maximum = page;
    }
    return maximum > 1 ? maximum : null;
  }

  String Function(int page) _pageUrlBuilder(Document document, Uri base) {
    final pageUrls = <int, String>{};
    for (final anchor in _paginationAnchors(document)) {
      final url = _directoryUrl(base, anchor.attributes['href']);
      if (url == null) continue;
      final target = Uri.parse(url);
      final page = _sameCatalog(document, base, target)
          ? _paginationTargetPage(document, base, anchor, target)
          : null;
      if (page != null) pageUrls[page] = _carryCatalogQuery(base, target);
    }

    final route = _catalogUri(document, base);
    final pathSegments = List<String>.unmodifiable(_segments(route));
    final queryParameters = Map<String, String>.unmodifiable(
      route.queryParameters,
    );
    final pageParameter = base.queryParameters.containsKey('from')
        ? 'from'
        : base.queryParameters.containsKey('page')
        ? 'page'
        : null;
    return (page) {
      if (page < 1) throw ArgumentError.value(page, 'page');
      final linkedPage = pageUrls[page];
      if (linkedPage != null) return linkedPage;
      if (pageParameter != null) {
        return route
            .replace(
              queryParameters: {...queryParameters, pageParameter: '$page'},
            )
            .toString();
      }
      if (page == 1) return route.toString();
      return route
          .replace(pathSegments: [...pathSegments, '$page', ''])
          .toString();
    };
  }

  String _carryCatalogQuery(Uri base, Uri target) {
    final parameters = Map<String, String>.of(target.queryParameters);
    for (final entry in base.queryParameters.entries) {
      if (entry.key == 'from' ||
          entry.key == 'page' ||
          parameters.containsKey(entry.key)) {
        continue;
      }
      parameters[entry.key] = entry.value;
    }
    return parameters.isEmpty
        ? target.toString()
        : target.replace(queryParameters: parameters).toString();
  }

  Uri _catalogUri(Document document, Uri uri) {
    final parameters = Map<String, String>.of(uri.queryParameters)
      ..remove('from')
      ..remove('page');
    var segments = _segments(uri);
    if (_isPathPage(document, uri) && segments.isNotEmpty) {
      segments = segments.sublist(0, segments.length - 1);
    }
    return _replacePathAndQuery(uri, [...segments, ''], parameters);
  }

  Uri _replacePathAndQuery(
    Uri uri,
    List<String> pathSegments,
    Map<String, String> queryParameters,
  ) => queryParameters.isEmpty
      ? Uri(
          scheme: uri.scheme,
          host: uri.host,
          pathSegments: pathSegments,
          fragment: uri.fragment.isEmpty ? null : uri.fragment,
        )
      : uri.replace(
          pathSegments: pathSegments,
          queryParameters: queryParameters,
        );

  List<String> _catalogPathSegments(Document document, Uri uri) =>
      _segments(_catalogUri(document, uri));

  bool _isPathPage(Document document, Uri uri) {
    final segments = _segments(uri);
    if (segments.isEmpty || int.tryParse(segments.last) == null) return false;
    final activePage = _activePage(document);
    if (activePage != null) return activePage == int.parse(segments.last);
    final minimumSegments = switch (segments.first) {
      'categories' || 'models' => 3,
      'search' => 3,
      _ => 2,
    };
    return segments.length >= minimumSegments;
  }

  bool _sameCatalog(Document document, Uri base, Uri target) {
    if (target.scheme != 'https' || target.host.toLowerCase() != 'jable.tv') {
      return false;
    }
    final root = _catalogPathSegments(document, base);
    final targetSegments = _segments(target);
    return _sameSegments(targetSegments, root) ||
        (targetSegments.length == root.length + 1 &&
            _sameSegments(targetSegments.take(root.length), root) &&
            int.tryParse(targetSegments.last) != null);
  }

  bool _sameSegments(Iterable<String> first, Iterable<String> second) {
    final left = first.toList();
    final right = second.toList();
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  int? _pageNumber(Uri uri) {
    final from = int.tryParse(uri.queryParameters['from'] ?? '');
    if (from != null && from > 0) return from;
    final page = int.tryParse(uri.queryParameters['page'] ?? '');
    if (page != null && page > 0) return page;
    final segments = _segments(uri);
    final minimumSegments = switch (segments.firstOrNull) {
      'categories' || 'models' || 'search' => 3,
      _ => 2,
    };
    if (segments.length < minimumSegments) return null;
    return int.tryParse(segments.last);
  }

  Uri _sourceUri(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host.toLowerCase() != 'jable.tv' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty) {
      throw VideoSourceException(
        'Jable returned an unsupported page address.',
        sourceKey: sourceKey,
        sourceUrl: uri.toString(),
      );
    }
    return uri;
  }

  String? _directoryUrl(Uri base, String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return null;
    final resolved = base.resolveUri(uri);
    if (resolved.scheme != 'https' ||
        resolved.host.toLowerCase() != 'jable.tv' ||
        resolved.port != 443 ||
        resolved.userInfo.isNotEmpty) {
      return null;
    }
    return resolved.toString();
  }

  String _absoluteUrl(Uri base, String value) => base.resolve(value).toString();

  List<String> _segments(Uri uri) =>
      uri.pathSegments.where((segment) => segment.isNotEmpty).toList();

  String? _videoId(String url) {
    final segments = _segments(Uri.parse(url));
    if (segments.length < 2 || segments.first != 'videos') return null;
    return segments[1];
  }

  void _ensureGeneration(int generation, Uri uri) {
    if (_disposed || generation != _generation) {
      throw VideoSourceException(
        'Jable session changed while loading the page.',
        sourceKey: sourceKey,
        sourceUrl: uri.toString(),
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    _advanceSessionGeneration();
    account.dispose();
    restoreNativeTransport();
    _disposed = true;
    if (_ownsDio) _dio.close(force: true);
  }
}

extension on String? {
  String? get takeIfNotEmpty {
    final value = this?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}

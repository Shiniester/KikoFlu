import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../services/proxy_config.dart';
import 'missav_browser_adapter.dart';
import 'video_models.dart';

class MissavClient extends ChangeNotifier {
  MissavClient({
    Dio? dio,
    Dio? metadataDio,
    FlutterSecureStorage? secureStorage,
    this.restoreSavedSession,
  }) : _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           ),
       _dio = dio ?? Dio(_defaultOptions()),
       _metadataDio =
           metadataDio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 5),
               receiveTimeout: const Duration(seconds: 5),
               sendTimeout: const Duration(seconds: 5),
               followRedirects: false,
             ),
           ) {
    if (dio == null) {
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () =>
            HttpClient()..findProxy = ProxyConfig.findProxyFor,
      );
    }
    if (metadataDio == null) {
      _metadataDio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () =>
            HttpClient()..findProxy = ProxyConfig.findProxyFor,
      );
    }
    _nativeAdapter = _dio.httpClientAdapter;
  }

  static const origin = 'https://missav.ai';
  static const _cookieKey = 'missav_session_cookie';
  static const _sessionRecordKey = 'missav_verified_session';
  static const _defaultUserAgent = 'Mozilla/5.0';
  static const _pageLimit = 5;
  // MissAV publishes this frontend token for Recombee catalog requests.
  static const _metadataPublicToken =
      'Ikkg568nlM51RHvldlPvc2GzZPE9R4XGzaH9Qj4zK9npbbbTly1gj9K4mgRn0QlV';
  // These categories belong to MissAV's uncensored navigation section.
  static const _uncensoredTypes = {
    'uncensored',
    'uncensored-leak',
    'fc2',
    'heyzo',
    'tokyo-hot',
    '1pondo',
    'caribbeancom',
    'caribbeancompr',
    '10musume',
    'pacopacomama',
    'gachinco',
    'xxx-av',
    'married-scent',
    'naughty4610',
    'naughty0930',
  };

  final FlutterSecureStorage _secureStorage;
  final Future<void> Function(MissavClient client, int expectedGeneration)?
  restoreSavedSession;
  final Dio _dio;
  final Dio _metadataDio;
  late final HttpClientAdapter _nativeAdapter;
  HttpClientAdapter? _browserAdapter;
  Uri Function(Uri)? _mediaRoute;
  int _sessionGeneration = 0;
  CancelToken _sessionCancelToken = CancelToken();
  Future<void> _pendingSessionWrite = Future.value();
  Future<void>? _initializing;
  Completer<void>? _sessionRestoration;
  bool _initialized = false;
  String? _cookie;
  String _userAgent = _defaultUserAgent;
  String? _accountName;
  String _locale = 'cn';
  String _homeUrl = '$origin/cn';
  bool _isLoggedIn = false;
  bool _disposed = false;

  bool get isLoggedIn => _isLoggedIn;
  int get sessionGeneration => _sessionGeneration;
  String? get accountName => _accountName;
  String get homeUrl => _homeUrl;

  bool setLocale(String languageTag) {
    final parts = languageTag.replaceAll('_', '-').toLowerCase().split('-');
    final locale = switch (parts.first) {
      'zh' =>
        parts.any(const {'hant', 'tw', 'hk', 'mo'}.contains) ? 'zh' : 'cn',
      'ja' => 'ja',
      _ => 'en',
    };
    if (_locale == locale) return false;
    _locale = locale;
    _homeUrl = '$origin${_localePrefix.isEmpty ? '/' : _localePrefix}';
    return true;
  }

  String collectionUrl(String kind) {
    final path = switch (kind) {
      'favorites' => 'saved',
      'actorFavorites' => 'saved/actresses',
      'playlists' => 'playlists',
      'history' => 'history',
      _ => throw ArgumentError.value(kind, 'kind'),
    };
    return '$origin$_localePrefix/$path';
  }

  void useVerifiedBrowserTransport(
    HttpClientAdapter adapter, {
    Uri Function(Uri)? mediaRoute,
  }) {
    if (_disposed) return;
    if (identical(adapter, _nativeAdapter)) {
      restoreNativeTransport();
      return;
    }
    if (identical(adapter, _browserAdapter)) return;

    final previousBrowserAdapter = _browserAdapter;
    _advanceSessionGeneration();
    _browserAdapter = adapter;
    _mediaRoute = mediaRoute;
    _dio.httpClientAdapter = adapter;
    if (previousBrowserAdapter != null &&
        !identical(previousBrowserAdapter, _nativeAdapter)) {
      previousBrowserAdapter.close(force: true);
    }
    notifyListeners();
  }

  void restoreNativeTransport() {
    if (_disposed) return;
    _advanceSessionGeneration();
    final browserAdapter = _browserAdapter;
    _browserAdapter = null;
    _mediaRoute = null;
    _dio.httpClientAdapter = _nativeAdapter;
    if (browserAdapter != null && !identical(browserAdapter, _nativeAdapter)) {
      browserAdapter.close(force: true);
    }
    notifyListeners();
  }

  Future<void> initialize() async {
    if (_initialized) return;
    await (_initializing ??= _loadSession());
  }

  Future<void> _prepareOnlineAccess() async {
    await initialize();
    final browser = _browserAdapter;
    if (browser is MissavBrowserAdapter && browser.isClosed) {
      restoreNativeTransport();
    }
    final pending = _sessionRestoration;
    if (pending != null) {
      await pending.future;
      return;
    }
    if (_browserAdapter != null || _cookie?.isNotEmpty != true) return;
    final restorer = restoreSavedSession;
    if (restorer == null) return;

    final generation = _sessionGeneration;
    final restoration = Completer<void>();
    _sessionRestoration = restoration;
    unawaited(_runSessionRestoration(restorer, generation, restoration));
    await restoration.future;
  }

  Future<void> _runSessionRestoration(
    Future<void> Function(MissavClient client, int expectedGeneration) restorer,
    int generation,
    Completer<void> restoration,
  ) async {
    try {
      await restorer(this, generation);
      if (_disposed || _browserAdapter == null) {
        throw const MissavException(
          'MissAV browser session could not be restored.',
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

  Future<void> _loadSession() async {
    final generation = _sessionGeneration;
    try {
      final record = await _secureStorage.read(key: _sessionRecordKey);
      final legacyCookie = await _secureStorage.read(key: _cookieKey);
      final session = _decodeStoredSession(record);
      if (generation == _sessionGeneration && !_disposed) {
        _cookie = session?.cookie ?? legacyCookie;
        _userAgent = session?.userAgent ?? _defaultUserAgent;
        _initialized = true;
      }
    } finally {
      _initializing = null;
    }
  }

  Future<VideoCatalogPage> browse(String url) async {
    await _prepareOnlineAccess();
    return _browse(url);
  }

  Future<void> checkBrowserAccess() async {
    await initialize();
    final generation = _sessionGeneration;
    final locale = _locale;
    final uri = _localizedSourceUri(homeUrl);
    final document = await _loadDocument(uri, generation);
    if (_locale != locale) {
      throw MissavException(
        'MissAV language changed during the request.',
        sourceUrl: uri.toString(),
      );
    }
    _updateAccountFromPage(document);
    _updateHomeUrl(document, uri);
  }

  Future<VideoCatalogPage> _browse(String url) async {
    final generation = _sessionGeneration;
    final uri = _localizedSourceUri(url);
    final locale = _locale;
    final document = await _loadDocument(uri, generation);
    if (_locale != locale) {
      throw MissavException(
        'MissAV language changed during the request.',
        sourceUrl: uri.toString(),
      );
    }
    _updateAccountFromPage(document);
    _updateHomeUrl(document, uri);
    final videos = await _enrichVideos(_parseVideos(document, uri));
    _checkGeneration(generation, uri);
    if (_locale != locale) {
      throw MissavException(
        'MissAV language changed during the request.',
        sourceUrl: uri.toString(),
      );
    }

    return VideoCatalogPage(
      title: _pageTitle(document),
      url: uri.toString(),
      videos: videos,
      links: _parseLinks(document, uri),
      navigation: _parseNavigation(document, uri),
      nextUrl: _paginationUrl(document, uri, 'next'),
      previousUrl: _paginationUrl(document, uri, 'prev'),
      currentPage: _pageNumber(uri) ?? 1,
      jumpMaxPage: _jumpMaxPage(document, uri),
    );
  }

  Future<List<VideoItem>> _enrichVideos(List<VideoItem> videos) async {
    if (videos.isEmpty) return videos;
    final localePrefix = _localePrefix;
    final ids = videos
        .map((video) => video.id.toLowerCase())
        .where((id) => RegExp(r'^[a-z0-9_:@.\-]+$').hasMatch(id))
        .toSet();
    if (ids.isEmpty) return videos;
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    const path = '/missav-default/recomms/users/anonymous/items/';
    final unsigned = '$path?frontend_timestamp=$timestamp';
    final signature = Hmac(
      sha1,
      utf8.encode(_metadataPublicToken),
    ).convert(utf8.encode(unsigned));
    try {
      final response = await _metadataDio.post<Object?>(
        'https://client-rapi-missav.recombee.com$unsigned&frontend_sign=$signature',
        data: {
          'count': ids.length,
          'cascadeCreate': true,
          'returnProperties': true,
          'filter': "'itemId' in {${ids.map(jsonEncode).join(',')}}",
        },
        cancelToken: _sessionCancelToken,
        options: Options(
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
        ),
      );
      final data = response.data;
      if (data is! Map || data['recomms'] is! List) return videos;
      final valuesById = <String, Map>{};
      for (final entry in data['recomms'] as List) {
        if (entry is! Map ||
            entry['id'] is! String ||
            entry['values'] is! Map) {
          continue;
        }
        final id = (entry['id'] as String).toLowerCase();
        if (ids.contains(id)) valuesById[id] = entry['values'] as Map;
      }
      return videos.map((video) {
        final values = valuesById[video.id.toLowerCase()];
        if (values == null) return video;
        List<String> names(String field) {
          final value = values[field];
          if (value is! List) return [];
          return value
              .whereType<String>()
              .map((name) => name.trim())
              .where((name) => name.isNotEmpty)
              .toSet()
              .toList();
        }

        List<VideoLink> links(String field, String route, VideoLinkKind kind) {
          // Recombee genre names use MissAV's Japanese slugs.
          final prefix = field == 'genres' ? '/ja' : localePrefix;
          return names(field)
              .map(
                (name) => VideoLink(
                  label: name,
                  url: '$origin$prefix/$route/${Uri.encodeComponent(name)}',
                  kind: kind,
                ),
              )
              .toList();
        }

        final actors = <String, VideoLink>{
          for (final actor in links(
            'actresses',
            'actresses',
            VideoLinkKind.actor,
          ))
            actor.label: actor,
          for (final actor in video.actors) actor.label: actor,
        };
        final tags = <String, VideoLink>{
          for (final tag in links('genres', 'genres', VideoLinkKind.category))
            tag.label: tag,
          for (final tag in video.tags) tag.label: tag,
        };
        final duration = values['duration'];
        final releasedAt = values['released_at'];
        return VideoItem(
          id: video.id,
          title: video.title,
          pageUrl: video.pageUrl,
          cover: video.cover,
          durationSeconds: duration is num && duration > 0
              ? duration.round()
              : video.durationSeconds,
          releaseDate: releasedAt is num && releasedAt > 0
              ? DateTime.fromMillisecondsSinceEpoch(
                  (releasedAt * 1000).round(),
                  isUtc: true,
                ).toIso8601String().substring(0, 10)
              : video.releaseDate,
          actors: actors.values.toList(),
          tags: tags.values.toList(),
          makers: {...video.makers, ...names('markers')}.toList(),
          labels: {...video.labels, ...names('labels')}.toList(),
          series: {...video.series, ...names('series')}.toList(),
          directors: {...video.directors, ...names('directors')}.toList(),
          hasSubtitles:
              video.hasSubtitles ||
              values['has_chinese_subtitle'] == true ||
              values['has_english_subtitle'] == true,
          isUncensored:
              video.isUncensored ||
              values['is_uncensored_leak'] == true ||
              _uncensoredTypes.contains(values['type']),
        );
      }).toList();
    } catch (_) {
      // Catalog browsing stays available when optional metadata cannot be read.
      return videos;
    }
  }

  Future<VideoCatalogPage> search(String query) async {
    final path = '$_localePrefix/search/${Uri.encodeComponent(query)}';
    return browse('$origin$path');
  }

  Future<VideoCatalogPage> searchFilterOptions(
    VideoSearchFilterKind kind, {
    String? pageUrl,
  }) async {
    final route = switch (kind) {
      VideoSearchFilterKind.genre => 'genres',
      VideoSearchFilterKind.actor => 'actresses',
      VideoSearchFilterKind.studio => 'makers',
      VideoSearchFilterKind.series => 'series',
    };
    final roots = switch (kind) {
      VideoSearchFilterKind.genre => const {
        'genre',
        'genres',
        'category',
        'categories',
        'tag',
        'tags',
      },
      VideoSearchFilterKind.actor => const {'actresses', 'actors'},
      VideoSearchFilterKind.studio => const {
        'maker',
        'makers',
        'studio',
        'studios',
      },
      VideoSearchFilterKind.series => const {'series'},
    };
    final page = await browse(pageUrl ?? '$origin$_localePrefix/$route');
    return VideoCatalogPage(
      title: page.title,
      url: page.url,
      links: page.links
          .where((link) {
            final segments = Uri.parse(link.url).pathSegments
                .where((segment) => segment.isNotEmpty)
                .skipWhile(
                  (segment) =>
                      _sourceLanguages.contains(segment) ||
                      RegExp(r'^dm\d+$').hasMatch(segment),
                )
                .toList();
            return segments.length == 2 &&
                roots.contains(segments.first) &&
                segments.last != 'ranking';
          })
          .toList(growable: false),
      nextUrl: page.nextUrl,
      previousUrl: page.previousUrl,
      currentPage: page.currentPage,
      jumpMaxPage: page.jumpMaxPage,
    );
  }

  Future<List<VideoItem>> searchWithFilters(
    String query,
    List<VideoLink> filters, {
    bool Function()? isCurrent,
  }) async {
    await _prepareOnlineAccess();
    final generation = _sessionGeneration;
    final locale = _locale;
    final keyword = query.trim();
    // shortcut: Large catalogs need full pagination until a native combined-search API is verified.
    final sources = <String>{
      if (keyword.isNotEmpty)
        '$origin$_localePrefix/search/${Uri.encodeComponent(keyword)}',
      for (final filter in filters) _localizedSourceUri(filter.url).toString(),
    };
    final candidates = <String, VideoItem>{};
    var firstSource = true;
    for (final source in sources) {
      final first = _localizedSourceUri(source).removeFragment();
      final parameters = Map<String, String>.of(first.queryParameters)
        ..remove('page');
      String? next = first.replace(queryParameters: parameters).toString();
      final visited = <String>{};
      final matchingIds = <String>{};
      while (next != null && visited.add(next)) {
        if (isCurrent?.call() == false || _locale != locale) return [];
        _checkGeneration(generation, first);
        final page = await browse(next);
        if (isCurrent?.call() == false || _locale != locale) return [];
        _checkGeneration(generation, first);
        for (final video in page.videos) {
          if (firstSource) {
            candidates.putIfAbsent(video.id, () => video);
          } else if (candidates.containsKey(video.id)) {
            matchingIds.add(video.id);
          }
        }
        if (!firstSource && matchingIds.length == candidates.length) break;
        next = page.nextUrl;
      }
      if (!firstSource) {
        candidates.removeWhere((id, _) => !matchingIds.contains(id));
      }
      if (candidates.isEmpty) return [];
      firstSource = false;
    }
    return candidates.values.toList(growable: false);
  }

  Future<List<VideoItem>> searchCollection(
    String url,
    String query, {
    bool Function()? isCurrent,
  }) async {
    await _prepareOnlineAccess();
    final generation = _sessionGeneration;
    final locale = _locale;
    final first = _localizedSourceUri(url);
    final parameters = Map<String, String>.of(first.queryParameters)
      ..remove('page');
    String? next = first.replace(queryParameters: parameters).toString();
    final visited = <String>{};
    final seen = <String>{};
    final matches = <VideoItem>[];
    final needle = query.trim().toLowerCase();
    while (next != null && visited.add(next)) {
      if (isCurrent?.call() == false || _locale != locale) return [];
      _checkGeneration(generation, first);
      final page = await browse(next);
      if (isCurrent?.call() == false || _locale != locale) return [];
      _checkGeneration(generation, first);
      for (final video in page.videos) {
        if (seen.add(video.id) &&
            '${video.id} ${video.title}'.toLowerCase().contains(needle)) {
          matches.add(video);
        }
      }
      next = page.nextUrl;
    }
    return matches;
  }

  Future<VideoDetails> details(
    VideoItem item, {
    FutureOr<void> Function(VideoDetails)? onReady,
  }) async {
    await _prepareOnlineAccess();
    final generation = _sessionGeneration;
    final locale = _locale;
    final uri = _localizedSourceUri(item.pageUrl);
    final document = await _loadDocument(uri, generation);
    if (_locale != locale) {
      throw MissavException(
        'MissAV language changed during the request.',
        sourceUrl: uri.toString(),
      );
    }
    _updateAccountFromPage(document);
    final title =
        (document.querySelector('main h1') ?? document.querySelector('h1'))
            ?.text
            .trim();
    final poster = document
        .querySelector('video[data-poster]')
        ?.attributes['data-poster'];
    final metadata = _parseMetadata(document);
    final actors = _parseDetailLinks(document, uri, VideoLinkKind.actor);
    final tags = _parseDetailLinks(document, uri, VideoLinkKind.tag);
    final labels = '${uri.path} ${tags.map((tag) => tag.label).join(' ')}';
    final video = VideoItem(
      id: item.id,
      title: title?.isNotEmpty == true ? title! : item.title,
      pageUrl: uri.toString(),
      cover: poster?.isNotEmpty == true
          ? uri.resolve(poster!).toString()
          : item.cover,
      durationSeconds: item.durationSeconds,
      releaseDate:
          _releaseDate(
            _detailMetadataRows(
              document,
            ).expand((row) => row.querySelectorAll('time')),
          ) ??
          item.releaseDate,
      actors: actors.isEmpty ? item.actors : actors,
      tags: tags.isEmpty ? item.tags : tags,
      makers: item.makers,
      labels: item.labels,
      series: item.series,
      directors: item.directors,
      hasSubtitles: item.hasSubtitles || _hasSubtitleLabel(labels),
      isUncensored: item.isUncensored || _hasUncensoredLabel(labels),
    );
    final sourceId = _sourceId(document);
    final saved = _savedState(document);
    final related = _parseVideos(
      document,
      uri,
    ).where((related) => related.id != item.id).toList();
    final initialDetails = VideoDetails(
      video: video,
      description: _parseDescription(document),
      metadata: metadata,
      actors: video.actors,
      tags: video.tags,
      related: related,
      streams: _parseStreams(document, uri, userAgent: _userAgent).map((
        stream,
      ) {
        final route = _mediaRoute;
        if (route == null) return stream;
        return VideoStream(
          label: stream.label,
          url: route(Uri.parse(stream.url)).toString(),
          isHls: stream.isHls,
        );
      }).toList(),
      sourceId: sourceId,
      isFavorite: sourceId == null ? saved : null,
    );
    await onReady?.call(initialDetails);
    return _supplementDetails(
      initialDetails,
      generation: generation,
      locale: locale,
      saved: saved,
      onReady: onReady,
    );
  }

  Future<VideoDetails> supplementDetails(
    VideoDetails details, {
    FutureOr<void> Function(VideoDetails)? onReady,
  }) async {
    await _prepareOnlineAccess();
    return _supplementDetails(
      details,
      generation: _sessionGeneration,
      locale: _locale,
      saved: details.isFavorite,
      onReady: onReady,
    );
  }

  Future<VideoDetails> _supplementDetails(
    VideoDetails initialDetails, {
    required int generation,
    required String locale,
    bool? saved,
    FutureOr<void> Function(VideoDetails)? onReady,
  }) async {
    final uri = _sourceUri(initialDetails.video.pageUrl);
    _checkGeneration(generation, uri);
    final enrichment = _enrichVideos([
      initialDetails.video,
      ...initialDetails.related,
    ]);
    final sourceId = initialDetails.sourceId;
    Object? accountError;
    StackTrace? accountTrace;
    if (sourceId != null) {
      final viewUri = Uri.parse(
        '$origin/api/items/${Uri.encodeComponent(sourceId)}/view',
      );
      try {
        final viewResponse = await _request(viewUri, generation: generation);
        _checkGeneration(generation, viewUri);
        final viewBody = _decodeObject(viewResponse.data, viewUri);
        if (viewBody['saved'] is bool) saved = viewBody['saved'] as bool;
        if (viewBody.containsKey('user')) {
          _updateAccountFromSource(viewBody['user']);
        }
      } catch (error, trace) {
        accountError = error;
        accountTrace = trace;
        saved = null;
      }
    }
    final enriched = await enrichment;
    final detailedVideo = enriched.first;
    _checkGeneration(generation, uri);
    if (_locale != locale) {
      throw MissavException(
        'MissAV language changed during the request.',
        sourceUrl: uri.toString(),
      );
    }
    final details = VideoDetails(
      video: detailedVideo,
      description: initialDetails.description,
      metadata: initialDetails.metadata,
      actors: detailedVideo.actors,
      tags: detailedVideo.tags,
      related: enriched.skip(1).toList(),
      streams: initialDetails.streams,
      sourceId: sourceId,
      isFavorite: saved,
    );
    if (accountError != null) {
      await onReady?.call(details);
      Error.throwWithStackTrace(accountError, accountTrace!);
    }
    return details;
  }

  Future<void> login({required String email, required String password}) async {
    await _prepareOnlineAccess();
    final generation = _advanceSessionGeneration();
    final uri = Uri.parse('$origin$_localePrefix/api/login');

    try {
      final response = await _request(
        uri,
        method: 'POST',
        data: {'email': email, 'password': password, 'remember': true},
        generation: generation,
      );
      if (generation != _sessionGeneration) {
        throw const MissavException('MissAV account changed during login.');
      }

      final body = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (body is! Map || body['user'] is! Map) {
        throw MissavException(
          'MissAV returned an invalid login response.',
          sourceUrl: uri.toString(),
        );
      }
      final user = Map<String, dynamic>.from(body['user'] as Map);
      _accountName = _accountNameFrom(user);
      _setAccountState(loggedIn: true, notify: false);
      notifyListeners();
    } on MissavException {
      rethrow;
    } on DioException catch (error) {
      throw MissavException(
        'MissAV login failed (${error.response?.statusCode ?? error.type.name}).',
        sourceUrl: uri.toString(),
      );
    } on FormatException {
      throw MissavException(
        'MissAV returned an invalid login response.',
        sourceUrl: uri.toString(),
      );
    }
  }

  Future<void> logout() async {
    await initialize();
    restoreNativeTransport();
    await _clearSession(_advanceSessionGeneration());
  }

  Future<void> importVerifiedSession({
    required String cookieHeader,
    required String userAgent,
    int? expectedGeneration,
  }) async {
    _validateHeaderValue(cookieHeader, 'cookieHeader');
    _validateHeaderValue(userAgent, 'userAgent');
    final previousGeneration = expectedGeneration ?? _sessionGeneration;
    await initialize();
    _checkGeneration(previousGeneration, Uri.parse(origin));

    final generation = _advanceSessionGeneration();
    final accountChanged = _isLoggedIn || _accountName != null;
    _cookie = cookieHeader;
    _userAgent = userAgent;
    _accountName = null;
    _setAccountState(loggedIn: false, notify: false);
    if (accountChanged && !_disposed) notifyListeners();

    await _writeSession(generation, () async {
      await _persistSession(
        generation,
        cookie: cookieHeader,
        userAgent: userAgent,
      );
    });
    if (generation != _sessionGeneration || _disposed) {
      throw const MissavException(
        'MissAV account changed during session import.',
      );
    }
  }

  Future<void> setVideoFavorite(VideoDetails details, bool favorite) async {
    await _prepareOnlineAccess();
    final sourceId = details.sourceId;
    if (sourceId == null || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sourceId)) {
      throw MissavUnsupportedException(
        capability: 'video favorites without a source item ID',
        sourceUrl: details.video.pageUrl,
      );
    }
    await _request(
      Uri.parse('$origin/api/items/${Uri.encodeComponent(sourceId)}/save'),
      method: favorite ? 'POST' : 'DELETE',
    );
  }

  Future<List<VideoLink>> playlistsFor(VideoItem item) async {
    await _prepareOnlineAccess();
    _sourceUri(item.pageUrl);
    final uri = Uri.parse(
      '$origin/api/playlists/${Uri.encodeComponent(item.id)}',
    );
    final response = await _request(uri);
    final body = _decodeObject(response.data, uri);
    final entries = body['data'];
    if (entries is! List) {
      throw MissavException(
        'MissAV returned an invalid playlist response.',
        sourceUrl: uri.toString(),
      );
    }
    return entries
        .whereType<Map>()
        .map((entry) {
          final key = entry['key'];
          final name = entry['name'];
          if (key is! String || name is! String) return null;
          return VideoLink(
            label: name,
            url: collectionUrl('playlists'),
            kind: VideoLinkKind.playlist,
            sourceKey: key,
            isAdded: entry['is_added'] is bool
                ? entry['is_added'] as bool
                : null,
          );
        })
        .whereType<VideoLink>()
        .toList();
  }

  Future<void> setActorFavorite(VideoLink actor, bool favorite) async {
    await _prepareOnlineAccess();
    final generation = _sessionGeneration;
    final actorUri = _localizedSourceUri(actor.url);
    final document = await _loadDocument(actorUri, generation);
    final sourceId = _actorSourceId(document);
    if (sourceId == null) {
      throw MissavUnsupportedException(
        capability: 'actor favorites without a source actor ID',
        sourceUrl: actor.url,
      );
    }
    final viewUri = Uri.parse('$origin/api/actresses/$sourceId/view');
    final viewResponse = await _request(viewUri, generation: generation);
    _checkGeneration(generation, viewUri);
    final viewBody = _decodeObject(viewResponse.data, viewUri);
    if (viewBody.containsKey('user')) {
      _updateAccountFromSource(viewBody['user']);
    }
    await _request(
      Uri.parse('$origin/api/actresses/$sourceId/save'),
      method: favorite ? 'POST' : 'DELETE',
      generation: generation,
    );
  }

  Future<void> createPlaylist(String title) async =>
      throw MissavUnsupportedException(
        capability: 'creating a playlist',
        sourceUrl: collectionUrl('playlists'),
      );

  Future<void> renamePlaylist(VideoLink playlist, String title) async =>
      throw MissavUnsupportedException(
        capability: 'renaming a playlist',
        sourceUrl: playlist.url,
      );

  Future<void> deletePlaylist(VideoLink playlist) async =>
      throw MissavUnsupportedException(
        capability: 'deleting a playlist',
        sourceUrl: playlist.url,
      );

  Future<void> addToPlaylist(VideoLink playlist, VideoItem item) =>
      _setPlaylistMembership(playlist, item, added: true);

  Future<void> removeFromPlaylist(VideoLink playlist, VideoItem item) =>
      _setPlaylistMembership(playlist, item, added: false);

  Future<void> _setPlaylistMembership(
    VideoLink playlist,
    VideoItem item, {
    required bool added,
  }) async {
    await _prepareOnlineAccess();
    final key = playlist.sourceKey;
    if (key == null || key.isEmpty) {
      throw MissavUnsupportedException(
        capability: 'playlist action without a source playlist key',
        sourceUrl: playlist.url,
      );
    }
    await _request(
      Uri.parse('$origin/api/playlists/${added ? 'add' : 'remove'}'),
      method: 'POST',
      data: {'dvdId': item.id, 'key': key},
    );
  }

  Future<void> clearWatchHistory() async {
    await _prepareOnlineAccess();
    await _request(Uri.parse('$origin/api/history'), method: 'DELETE');
  }

  Future<Document> _loadDocument(Uri uri, int generation) async {
    _checkGeneration(generation, uri);
    final adapter = _browserAdapter;
    final String body;
    if (adapter is MissavBrowserAdapter) {
      try {
        body = await adapter.loadDocument(
          uri,
          cancelToken: _sessionCancelToken,
        );
      } on DioException catch (error) {
        _checkGeneration(generation, uri);
        if (error.error is MissavException) throw error.error!;
        throw MissavException(
          'MissAV browser navigation failed (${error.type.name}).',
          sourceUrl: uri.toString(),
        );
      }
    } else {
      body = (await _request(uri, generation: generation)).data as String;
    }
    _checkGeneration(generation, uri);
    return _parsePage(body, uri);
  }

  Future<Response<dynamic>> _request(
    Uri uri, {
    String method = 'GET',
    Object? data,
    int? generation,
  }) async {
    if (generation == null) await _prepareOnlineAccess();
    final requestGeneration = generation ?? _sessionGeneration;
    final requestCancelToken = _sessionCancelToken;
    var requestUri = _sourceUri(uri.toString());
    var requestMethod = method;
    var requestData = data;

    for (var redirect = 0; redirect <= _pageLimit; redirect++) {
      _checkGeneration(requestGeneration, requestUri);
      final isApi = requestUri.pathSegments.contains('api');
      final headers = <String, dynamic>{
        'Accept': isApi
            ? 'application/json, text/plain, */*'
            : 'text/html,application/xhtml+xml,*/*',
        if (isApi) 'X-Requested-With': 'XMLHttpRequest',
        'User-Agent': _userAgent,
      };
      if (_isSource(requestUri)) {
        final cookie = _cookie;
        if (cookie != null && cookie.isNotEmpty) {
          headers['Cookie'] = cookie;
          final xsrfToken = _cookieValue('XSRF-TOKEN');
          if (xsrfToken != null) {
            headers['X-XSRF-TOKEN'] = Uri.decodeComponent(xsrfToken);
          }
        }
      }

      late final Response<dynamic> response;
      try {
        response = await _dio.request<dynamic>(
          requestUri.toString(),
          data: requestData,
          cancelToken: requestCancelToken,
          options: Options(
            method: requestMethod,
            headers: headers,
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 500,
          ),
        );
      } on DioException catch (error) {
        _checkGeneration(requestGeneration, requestUri);
        final wrappedError = error.error;
        if (wrappedError is MissavVerificationRequiredException) {
          throw wrappedError;
        }
        throw MissavException(
          'MissAV request failed (${error.response?.statusCode ?? error.type.name}).',
          sourceUrl: requestUri.toString(),
        );
      }
      _checkGeneration(requestGeneration, requestUri);

      final status = response.statusCode ?? 0;
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (_isChallengeResponse(response.data) ||
          response.headers.value('cf-mitigated')?.trim().toLowerCase() ==
              'challenge') {
        throw MissavVerificationRequiredException(
          sourceUrl: requestUri.toString(),
        );
      }
      await _saveResponseCookies(response, requestUri, requestGeneration);
      _checkGeneration(requestGeneration, requestUri);
      if (status >= 300 && status < 400 && location != null) {
        final redirectedUri = requestUri.resolve(location);
        if (!_isSource(redirectedUri)) {
          throw MissavUnsupportedException(
            capability: 'following a redirect outside MissAV',
            sourceUrl: redirectedUri.toString(),
          );
        }
        requestUri = redirectedUri;
        if (status == 303 ||
            ((status == 301 || status == 302) && requestMethod != 'GET')) {
          requestMethod = 'GET';
          requestData = null;
        }
        continue;
      }
      if (status == HttpStatus.unauthorized) {
        throw MissavAuthenticationException(sourceUrl: requestUri.toString());
      }
      if (status < 200 || status >= 300) {
        throw MissavException(
          'MissAV returned HTTP $status.',
          sourceUrl: requestUri.toString(),
        );
      }
      return response;
    }

    throw MissavException(
      'MissAV redirected too many times.',
      sourceUrl: uri.toString(),
    );
  }

  Future<void> _saveResponseCookies(
    Response<dynamic> response,
    Uri uri,
    int generation,
  ) async {
    if (!_isSource(uri) || generation != _sessionGeneration) return;
    final values = response.headers['set-cookie'];
    if (values == null || values.isEmpty) return;

    await _writeSession(generation, () async {
      final cookies = <String, String>{};
      for (final part in (_cookie ?? '').split(';')) {
        final separator = part.indexOf('=');
        if (separator > 0) {
          cookies[part.substring(0, separator).trim()] = part
              .substring(separator + 1)
              .trim();
        }
      }
      for (final value in values) {
        try {
          final cookie = Cookie.fromSetCookieValue(value);
          if ((cookie.maxAge != null && cookie.maxAge! <= 0) ||
              (cookie.expires != null &&
                  cookie.expires!.isBefore(DateTime.now()))) {
            cookies.remove(cookie.name);
          } else {
            cookies[cookie.name] = cookie.value;
          }
        } on FormatException {
          continue;
        }
      }

      final updatedCookie = cookies.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
      await _persistSession(
        generation,
        cookie: updatedCookie.isEmpty ? null : updatedCookie,
        userAgent: _userAgent,
      );
      if (generation == _sessionGeneration) {
        _cookie = updatedCookie.isEmpty ? null : updatedCookie;
        if (updatedCookie.isEmpty) _userAgent = _defaultUserAgent;
      }
    });
  }

  Future<void> _persistSession(
    int generation, {
    required String? cookie,
    required String userAgent,
  }) async {
    if (cookie == null) {
      await _secureStorage.delete(key: _sessionRecordKey);
      if (generation == _sessionGeneration) {
        await _secureStorage.delete(key: _cookieKey);
      }
      return;
    }

    await _secureStorage.write(
      key: _sessionRecordKey,
      value: jsonEncode({'cookie': cookie, 'userAgent': userAgent}),
    );
    if (generation != _sessionGeneration) return;
    await _secureStorage.write(key: _cookieKey, value: cookie);
  }

  Future<void> _writeSession(
    int generation,
    Future<void> Function() write,
  ) async {
    final previous = _pendingSessionWrite;
    final completed = Completer<void>();
    _pendingSessionWrite = completed.future;
    await previous;
    try {
      if (generation == _sessionGeneration) await write();
    } finally {
      completed.complete();
    }
  }

  Future<void> _clearSession(int generation) async {
    if (generation != _sessionGeneration) return;
    final accountChanged = _isLoggedIn || _accountName != null;
    _cookie = null;
    _userAgent = _defaultUserAgent;
    _accountName = null;
    _setAccountState(loggedIn: false, notify: false);
    if (accountChanged && !_disposed) notifyListeners();
    await _writeSession(generation, () async {
      await _secureStorage.delete(key: _sessionRecordKey);
      await _secureStorage.delete(key: _cookieKey);
    });
  }

  static ({String cookie, String userAgent})? _decodeStoredSession(
    String? value,
  ) {
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map &&
          decoded['cookie'] is String &&
          decoded['userAgent'] is String) {
        final cookie = decoded['cookie'] as String;
        final userAgent = decoded['userAgent'] as String;
        _validateHeaderValue(cookie, 'cookie');
        _validateHeaderValue(userAgent, 'userAgent');
        return (cookie: cookie, userAgent: userAgent);
      }
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
    return null;
  }

  static void _validateHeaderValue(String value, String name) {
    if (value.trim().isEmpty ||
        value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw ArgumentError.value(value, name, 'must be a valid HTTP header');
    }
  }

  String? _cookieValue(String name) {
    for (final pair in (_cookie ?? '').split(';')) {
      final separator = pair.indexOf('=');
      if (separator > 0 && pair.substring(0, separator).trim() == name) {
        return pair.substring(separator + 1).trim();
      }
    }
    return null;
  }

  void _setAccountState({required bool loggedIn, bool notify = true}) {
    if (_isLoggedIn == loggedIn) return;
    _isLoggedIn = loggedIn;
    if (notify && !_disposed) notifyListeners();
  }

  int _advanceSessionGeneration() {
    _sessionCancelToken.cancel('MissAV account changed.');
    _sessionCancelToken = CancelToken();
    return ++_sessionGeneration;
  }

  void _checkGeneration(int generation, Uri uri) {
    if (_disposed || generation != _sessionGeneration) {
      throw MissavException(
        'MissAV account changed during the request.',
        sourceUrl: uri.toString(),
      );
    }
  }

  static Uri _sourceUri(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !_isSource(uri)) {
      throw MissavUnsupportedException(
        capability: 'opening a non-MissAV page in the native client',
        sourceUrl: url,
      );
    }
    return uri;
  }

  static bool _isSource(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      uri.host.toLowerCase() == 'missav.ai';

  static const _sourceLanguages = {
    'cn',
    'zh',
    'ja',
    'en',
    'ko',
    'ms',
    'th',
    'de',
    'fr',
    'vi',
    'id',
    'fil',
    'pt',
  };

  String get _localePrefix => _locale == 'zh' ? '' : '/$_locale';

  Uri _localizedSourceUri(String url) {
    final uri = _sourceUri(url);
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    final index =
        segments.isNotEmpty && RegExp(r'^dm\d+$').hasMatch(segments.first)
        ? 1
        : 0;
    final hasLocale =
        segments.length > index && _sourceLanguages.contains(segments[index]);
    final routeIndex = index + (hasLocale ? 1 : 0);
    // Genre slugs only select the right category in their source language.
    if (segments.length == routeIndex + 2 && segments[routeIndex] == 'genres') {
      return uri;
    }
    if (hasLocale) {
      segments.removeAt(index);
    }
    if (_locale != 'zh') segments.insert(index, _locale);
    return uri.replace(pathSegments: segments);
  }

  static Document _parsePage(String source, Uri uri) {
    if (_isChallengeResponse(source)) {
      throw MissavVerificationRequiredException(sourceUrl: uri.toString());
    }
    return html_parser.parse(source);
  }

  static bool _isChallengeResponse(Object? body) {
    if (body is! String) return false;
    final lower = body.toLowerCase();
    final title = RegExp(
      r'<title[^>]*>(.*?)</title>',
      dotAll: true,
    ).firstMatch(lower)?.group(1)?.trim();
    if (title != null &&
        (title.startsWith('just a moment') ||
            (title.contains('attention required') &&
                title.contains('cloudflare')))) {
      return true;
    }
    if (RegExp(r'\bwindow\s*\.\s*_cf_chl_opt\b').hasMatch(lower)) {
      return true;
    }
    final hasChallengeForm = RegExp(
      r"""<form\b[^>]*\bid=["']challenge-form["'][^>]*>""",
    ).hasMatch(lower);
    final hasChallengeAction = RegExp(
      r"""<form\b[^>]*\baction=["'][^"']*/cdn-cgi/challenge-platform/""",
    ).hasMatch(lower);
    final hasCaptchaAction = RegExp(
      r"""<form\b[^>]*\baction=["'][^"']*/cdn-cgi/l/chk_captcha""",
    ).hasMatch(lower);
    if (hasChallengeForm || hasChallengeAction || hasCaptchaAction) {
      return true;
    }
    return lower.contains('orchestrate') && lower.contains('chl_page');
  }

  void _updateHomeUrl(Document document, Uri pageUri) {
    for (final anchor in document.querySelectorAll('nav a[href]')) {
      final href = anchor.attributes['href'];
      if (href == null) continue;
      final candidate = pageUri.resolve(href);
      if (!_isSource(candidate)) continue;
      final segments = candidate.pathSegments
          .where((part) => part.isNotEmpty)
          .toList();
      if (segments.isNotEmpty && RegExp(r'^dm\d+$').hasMatch(segments.first)) {
        segments.removeAt(0);
      }
      if ((_locale == 'zh' && segments.isEmpty) ||
          (segments.length == 1 && segments.single == _locale)) {
        _homeUrl = candidate.toString();
        return;
      }
    }
  }

  static String? _accountNameFrom(Map<String, dynamic> user) {
    for (final key in const ['email', 'username', 'name']) {
      final value = user[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  Map<String, dynamic> _decodeObject(Object? value, Uri uri) {
    try {
      final decoded = value is String ? jsonDecode(value) : value;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException catch (error) {
      throw MissavException(
        'MissAV returned an invalid response.',
        sourceUrl: uri.toString(),
        cause: error,
      );
    }
    throw MissavException(
      'MissAV returned an invalid response.',
      sourceUrl: uri.toString(),
    );
  }

  void _updateAccountFromSource(Object? sourceUser) {
    final previousName = _accountName;
    final previousLoginState = _isLoggedIn;
    if (sourceUser is Map) {
      _accountName = _accountNameFrom(Map<String, dynamic>.from(sourceUser));
      _setAccountState(loggedIn: true, notify: false);
    } else if (sourceUser == null) {
      _accountName = null;
      _setAccountState(loggedIn: false, notify: false);
    } else {
      return;
    }
    if (previousName != _accountName || previousLoginState != _isLoggedIn) {
      if (!_disposed) notifyListeners();
    }
  }

  void _updateAccountFromPage(Document document) {
    final sourceUser = _readAccountFromPage(document);
    // Public markup initializes user before /view confirms the session.
    if (sourceUser is Map) {
      _updateAccountFromSource(sourceUser);
    }
  }

  static Object? _readAccountFromPage(Document document) {
    for (final element in document.querySelectorAll('[x-data]')) {
      final source = element.attributes['x-data'] ?? '';
      final match = RegExp(r'\buser\s*:\s*(null|\{)').firstMatch(source);
      if (match == null) continue;
      if (match.group(1) == 'null') return null;
      final user = <String, dynamic>{};
      final property = RegExp(
        r'''['"]?(email|username|name)['"]?\s*:\s*(['"])(.*?)\2''',
      ).firstMatch(source.substring(match.end));
      if (property != null) user[property.group(1)!] = property.group(3);
      return user;
    }
    return null;
  }

  static String? _sourceId(Document document) {
    for (final element in document.querySelectorAll(
      'script, [x-init], [x-data]',
    )) {
      final source = '${element.text} ${element.attributes.values.join(' ')}';
      final match = RegExp(
        r'''/api/items/([A-Za-z0-9_-]+)/(?:save|view)\b''',
      ).firstMatch(source);
      if (match != null) return match.group(1);
    }
    return null;
  }

  static String? _actorSourceId(Document document) {
    for (final element in document.querySelectorAll(
      'script, [x-init], [x-data]',
    )) {
      final source = '${element.text} ${element.attributes.values.join(' ')}';
      final match = RegExp(
        r'''/api/actresses/(\d+)/(?:save|view)\b''',
      ).firstMatch(source);
      if (match != null) return match.group(1);
    }
    return null;
  }

  static bool? _savedState(Document document) {
    for (final element in document.querySelectorAll('[x-data]')) {
      final source = element.attributes['x-data'] ?? '';
      final match = RegExp(r'\bsaved\s*:\s*(true|false)\b').firstMatch(source);
      if (match != null) return match.group(1) == 'true';
    }
    return null;
  }

  static String _parseDescription(Document document) {
    final sourceDescription = document
        .querySelector(
          '[x-data*="showMore"] .mb-1.text-secondary.break-all.line-clamp-2',
        )
        ?.text
        .trim();
    if (sourceDescription?.isNotEmpty == true) return sourceDescription!;
    return document.querySelector('[itemprop="description"]')?.text.trim() ??
        document
            .querySelector('meta[name="description"]')
            ?.attributes['content']
            ?.trim() ??
        '';
  }

  static Map<String, String> _parseMetadata(Document document) {
    final metadata = <String, String>{};
    for (final row in _detailMetadataRows(document)) {
      final labelElement = row.querySelector('span');
      if (labelElement == null) continue;
      final label = _metadataLabel(labelElement);
      final value = row.nodes
          .where((node) => node != labelElement)
          .map((node) => node.text)
          .join()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (label.isNotEmpty && value.isNotEmpty) metadata[label] = value;
    }
    return metadata;
  }

  static Iterable<Element> _detailMetadataRows(Document document) =>
      document.querySelectorAll('div.text-secondary').where((row) {
        final label = row.children.isEmpty ? null : row.children.first;
        return label?.localName == 'span' &&
            RegExp(r'[:：]$').hasMatch(label!.text.trim());
      });

  static String _metadataLabel(Element element) =>
      element.text.trim().replaceAll(RegExp(r'[:：]$'), '').trim();

  static List<VideoLink> _parseDetailLinks(
    Document document,
    Uri pageUri,
    VideoLinkKind kind,
  ) {
    final seen = <String>{};
    final links = <VideoLink>[];
    for (final row in _detailMetadataRows(document)) {
      for (final anchor in row.querySelectorAll('a[href]')) {
        final href = anchor.attributes['href'];
        if (href == null) continue;
        final uri = pageUri.resolve(href);
        if (!_isSource(uri) || uri == pageUri || !seen.add(uri.toString())) {
          continue;
        }
        final label = anchor.text.trim();
        if (label.isEmpty) continue;
        final route = uri.path.toLowerCase();
        final isActor =
            route.contains('/actresses/') || route.contains('/actors/');
        final isTag =
            route.contains('/category') ||
            route.contains('/genre') ||
            route.contains('/tag') ||
            route.contains('/studio') ||
            route.contains('/label') ||
            route.contains('/maker') ||
            route.contains('/director') ||
            route.contains('/series');
        if (kind == VideoLinkKind.actor && !isActor) continue;
        if (kind == VideoLinkKind.tag && (!isTag || isActor)) continue;
        links.add(
          VideoLink(
            label: label,
            url: uri.toString(),
            kind: isActor ? VideoLinkKind.actor : _detailLinkKind(route),
          ),
        );
      }
    }
    return links;
  }

  static VideoLinkKind _detailLinkKind(String route) {
    if (route.contains('/genre') ||
        route.contains('/category') ||
        route.contains('/tag') ||
        route.contains('/label') ||
        route.contains('/series')) {
      return VideoLinkKind.category;
    }
    if (route.contains('/maker') || route.contains('/studio')) {
      return VideoLinkKind.studio;
    }
    return VideoLinkKind.other;
  }

  static List<VideoStream> _parseStreams(
    Document document,
    Uri pageUri, {
    required String userAgent,
  }) {
    final streams = <VideoStream>[];
    final urls = <String>{};
    for (final script in document.querySelectorAll('script')) {
      final text = _unpackPacker(script.text);
      if (text == null) continue;
      for (final match in RegExp(
        r'''\b(source\d*)\s*=\s*(['"])(.*?)\2''',
        dotAll: true,
      ).allMatches(text)) {
        final name = match.group(1)!;
        final url = match.group(3)!.replaceAll(r'\/', '/');
        final uri = Uri.tryParse(url);
        if (uri == null ||
            (uri.scheme != 'https' && uri.scheme != 'http') ||
            uri.host.isEmpty ||
            !RegExp(
              r'\.(m3u8|mp4)$',
              caseSensitive: false,
            ).hasMatch(uri.path) ||
            !urls.add(uri.toString())) {
          continue;
        }
        streams.add(
          VideoStream(
            label: name == 'source' ? 'Source' : 'Source ${name.substring(6)}',
            url: uri.toString(),
            headers: {
              HttpHeaders.refererHeader: pageUri.toString(),
              'Origin': origin,
              HttpHeaders.userAgentHeader: userAgent,
            },
            isHls: uri.path.toLowerCase().endsWith('.m3u8'),
          ),
        );
      }
    }
    return streams;
  }

  // Expands the packed token table without evaluating page JavaScript.
  static String? _unpackPacker(String source) {
    final match = RegExp(
      r'''eval\(function\(p,a,c,k,e,d\).*?\}\('((?:\\.|[^'])*)',\s*(\d+),\s*(\d+),\s*'((?:\\.|[^'])*)'\.split\('\|'\)''',
      dotAll: true,
    ).firstMatch(source);
    if (match == null) return null;
    final payload = match.group(1)!.replaceAll(r"\'", "'");
    final radix = int.parse(match.group(2)!);
    if (radix < 2 || radix > 62) return null;
    final count = int.parse(match.group(3)!);
    final words = match.group(4)!.split('|');
    final replacements = <String, String>{
      for (var index = 0; index < count && index < words.length; index++)
        if (words[index].isNotEmpty) _encodeRadix(index, radix): words[index],
    };
    return payload.replaceAllMapped(
      RegExp(r'\b\w+\b'),
      (token) => replacements[token[0]] ?? token[0]!,
    );
  }

  static String _encodeRadix(int value, int radix) {
    const digits =
        '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    if (value == 0) return '0';
    var remainder = value;
    final result = StringBuffer();
    while (remainder > 0) {
      result.write(digits[remainder % radix]);
      remainder ~/= radix;
    }
    return result.toString().split('').reversed.join();
  }

  static String _pageTitle(Document document) {
    final heading =
        (document.querySelector('main h1') ?? document.querySelector('h1'))
            ?.text
            .trim();
    return heading?.isNotEmpty == true
        ? heading!
        : document.querySelector('title')?.text.trim() ?? '';
  }

  static List<VideoItem> _parseVideos(Document document, Uri pageUri) {
    final seen = <String>{};
    final videos = <VideoItem>[];
    for (final card in document.querySelectorAll(
      'div.relative.aspect-w-16.aspect-h-9',
    )) {
      final anchor = card.querySelector('a[href]');
      final image = card.querySelector('img[alt]');
      if (anchor == null || image == null) continue;
      final href = anchor.attributes['href'];
      final title = image.attributes['alt']?.trim() ?? '';
      if (href == null || title.isEmpty) continue;
      final itemUri = pageUri.resolve(href).removeFragment();
      if (!_isSource(itemUri)) continue;
      final id = itemUri.pathSegments.isEmpty ? '' : itemUri.pathSegments.last;
      if (id.isEmpty || !seen.add(id)) continue;
      final dataCover = image.attributes['data-src'];
      final sourceCover = image.attributes['src'] ?? '';
      final cover = dataCover?.isNotEmpty == true
          ? pageUri.resolve(dataCover!).toString()
          : sourceCover.startsWith('data:')
          ? ''
          : sourceCover.isEmpty
          ? ''
          : pageUri.resolve(sourceCover).toString();
      final parent = card.parent;
      final information =
          parent != null &&
              parent.localName == 'div' &&
              parent.querySelector('h1, video') == null &&
              parent
                      .querySelectorAll('div.relative.aspect-w-16.aspect-h-9')
                      .length ==
                  1
          ? parent
          : card;
      final links = _parseCardLinks(information, pageUri);
      final badgeLabels = card
          .querySelectorAll('.bottom-1.left-1, [title], [aria-label]')
          .map(
            (element) =>
                '${element.text} ${element.attributes['title'] ?? ''} ${element.attributes['aria-label'] ?? ''}',
          )
          .join(' ');
      final labels =
          '${itemUri.path} $badgeLabels ${links.map((link) => link.label).join(' ')}';

      videos.add(
        VideoItem(
          id: id,
          title: title,
          pageUrl: itemUri.toString(),
          cover: cover,
          durationSeconds: _durationSeconds(
            card.querySelector('span.bottom-1.right-1')?.text.trim(),
          ),
          releaseDate: _releaseDate(information.querySelectorAll('time')),
          actors: links
              .where((link) => link.kind == VideoLinkKind.actor)
              .toList(),
          tags: links
              .where((link) => link.kind != VideoLinkKind.actor)
              .toList(),
          hasSubtitles: _hasSubtitleLabel(labels),
          isUncensored: _hasUncensoredLabel(labels),
        ),
      );
    }
    return videos;
  }

  static List<VideoLink> _parseCardLinks(Element card, Uri pageUri) {
    final seen = <String>{};
    final links = <VideoLink>[];
    for (final anchor in card.querySelectorAll('a[href]')) {
      final uri = pageUri.resolve(anchor.attributes['href']!).removeFragment();
      final kind = _browseLinkKind(uri);
      final label = anchor.text.trim();
      if (!_isSource(uri) ||
          label.isEmpty ||
          !const {
            VideoLinkKind.actor,
            VideoLinkKind.category,
            VideoLinkKind.tag,
            VideoLinkKind.studio,
          }.contains(kind) ||
          !seen.add(uri.toString())) {
        continue;
      }
      links.add(VideoLink(label: label, url: uri.toString(), kind: kind));
    }
    return links;
  }

  static String? _releaseDate(Iterable<Element> times) {
    for (final time in times) {
      final value = time.attributes['datetime'] ?? time.text.trim();
      if (DateTime.tryParse(value) != null && value.length >= 10) {
        return value.substring(0, 10);
      }
    }
    return null;
  }

  static bool _hasSubtitleLabel(String value) =>
      RegExp(r'字幕|subtitles?|subtitled', caseSensitive: false).hasMatch(value);

  static bool _hasUncensoredLabel(String value) =>
      RegExp(r'无码|無碼|無修正|uncensored', caseSensitive: false).hasMatch(value);

  List<VideoLink> _parseNavigation(Document document, Uri pageUri) {
    final seen = <String>{};
    return document
        .querySelectorAll('nav a[href]')
        .map((anchor) {
          final url = anchor.attributes['href'];
          if (url == null || url.startsWith('#')) return null;
          final label = anchor.text.trim();
          if (label.isEmpty) return null;
          final uri = pageUri.resolve(url).removeFragment();
          if (!_isSource(uri) ||
              _excludeDirectoryAnchor(anchor, uri) ||
              !seen.add(uri.toString())) {
            return null;
          }
          return VideoLink(
            label: label,
            url: uri.toString(),
            kind: VideoLinkKind.navigation,
          );
        })
        .whereType<VideoLink>()
        .toList();
  }

  static List<VideoLink> _parseLinks(Document document, Uri pageUri) {
    final seen = <String>{};
    final videoAnchors = document
        .querySelectorAll('div.relative.aspect-w-16.aspect-h-9 a[href]')
        .toSet();
    final videoUrls = videoAnchors
        .map(
          (anchor) => pageUri
              .resolve(anchor.attributes['href']!)
              .removeFragment()
              .toString(),
        )
        .toSet();
    final navigationAnchors = document.querySelectorAll('nav a[href]').toSet();
    final links = <VideoLink>[];
    for (final anchor in document.querySelectorAll('a[href]')) {
      if (videoAnchors.contains(anchor) ||
          navigationAnchors.contains(anchor) ||
          _isLanguageAnchor(anchor)) {
        continue;
      }
      final href = anchor.attributes['href'];
      if (href == null || href.startsWith('#')) continue;
      final uri = pageUri.resolve(href).removeFragment();
      if (!_isSource(uri) || uri == pageUri) {
        continue;
      }
      if (_excludeDirectoryAnchor(anchor, uri)) continue;
      if (videoUrls.contains(uri.toString())) continue;
      final image = anchor.querySelector('img[alt]');
      final label = anchor.text.trim().isNotEmpty
          ? anchor.text.trim()
          : image?.attributes['alt']?.trim() ?? '';
      if (label.isEmpty || !seen.add(uri.toString())) continue;
      final imageSource =
          image?.attributes['data-src'] ?? image?.attributes['src'] ?? '';
      final cover = imageSource.isEmpty || imageSource.startsWith('data:')
          ? ''
          : pageUri.resolve(imageSource).toString();
      links.add(
        VideoLink(
          label: label,
          url: uri.toString(),
          cover: cover,
          kind: _browseLinkKind(uri),
        ),
      );
    }
    return links;
  }

  static bool _isLanguageAnchor(Element anchor) {
    if (anchor.attributes.containsKey('hreflang') ||
        (anchor.attributes[':href'] ?? '').contains('localizedUrl(') ||
        (anchor.attributes['x-bind:href'] ?? '').contains('localizedUrl(')) {
      return true;
    }
    final label = anchor.text.trim().toLowerCase();
    return const {
      '简体中文',
      '簡體中文',
      '繁体中文',
      '繁體中文',
      'english',
      '日本語',
      '한국의',
      '한국어',
      'melayu',
      'ไทย',
      'deutsch',
      'français',
      'tiếng việt',
      'bahasa indonesia',
      'filipino',
      'português',
    }.contains(label);
  }

  static bool _excludeDirectoryAnchor(Element anchor, Uri uri) {
    final label = anchor.text.trim().toLowerCase();
    final relations = (anchor.attributes['rel'] ?? '').split(' ');
    final route = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .skipWhile(
          (segment) =>
              _sourceLanguages.contains(segment) ||
              RegExp(r'^dm\d+$').hasMatch(segment),
        )
        .join('/');
    return _isLanguageAnchor(anchor) ||
        const {'ads', 'contact', 'terms', 'upload'}.contains(route) ||
        _pageNumber(uri) != null ||
        relations.any(const {'next', 'prev', 'first', 'last'}.contains) ||
        RegExp(r'\bvip\b').hasMatch(label) ||
        RegExp(
          r'/(vip|premium|subscription|upgrade)(/|$)',
        ).hasMatch(uri.path) ||
        RegExp(r'/(actresses|actors)/ranking(/|$)').hasMatch(uri.path);
  }

  static int? _pageNumber(Uri uri) {
    final page = int.tryParse(uri.queryParameters['page'] ?? '');
    return page != null && page > 0 ? page : null;
  }

  static int? _jumpMaxPage(Document document, Uri pageUri) {
    int? maximum;
    final prefix = RegExp(r'^/dm\d+(?=/|$)');
    final path = pageUri.path.replaceFirst(prefix, '');
    final sourceQuery = Map<String, String>.of(pageUri.queryParameters)
      ..remove('page');
    for (final anchor in document.querySelectorAll('a[href]')) {
      final uri = pageUri.resolve(anchor.attributes['href']!);
      if (!_isSource(uri) || uri.path.replaceFirst(prefix, '') != path) {
        continue;
      }
      final targetQuery = Map<String, String>.of(uri.queryParameters)
        ..remove('page');
      if (!mapEquals(sourceQuery, targetQuery)) continue;
      final page = _pageNumber(uri);
      if (page != null && (maximum == null || page > maximum)) maximum = page;
    }
    final current = _pageNumber(pageUri) ?? 1;
    return maximum == null ? null : (maximum < current ? current : maximum);
  }

  static VideoLinkKind _browseLinkKind(Uri uri) {
    final route = uri.path.toLowerCase();
    if (route.contains('/playlists')) return VideoLinkKind.playlist;
    if (route.contains('/actresses') || route.contains('/actors')) {
      return VideoLinkKind.actor;
    }
    if (route.contains('/maker') || route.contains('/studio')) {
      return VideoLinkKind.studio;
    }
    if (route.contains('/category') ||
        route.contains('/genre') ||
        route.contains('/tag') ||
        route.contains('/director') ||
        route.contains('/label') ||
        route.contains('/series')) {
      return VideoLinkKind.category;
    }
    if (RegExp(r'/(saved|favorites|history)(/|$)').hasMatch(route)) {
      return VideoLinkKind.collection;
    }
    return VideoLinkKind.other;
  }

  static String? _paginationUrl(
    Document document,
    Uri pageUri,
    String direction,
  ) {
    Element? candidate = document.querySelector('a[rel="$direction"][href]');
    if (candidate == null) {
      for (final link in document.querySelectorAll('a[href]')) {
        final label = link.text.trim().toLowerCase();
        final aria = link.attributes['aria-label']?.toLowerCase() ?? '';
        final matches = direction == 'next'
            ? const {'next', '›', '»', '下一页', '下一頁', '次へ'}.contains(label) ||
                  aria.contains('next')
            : const {
                    'previous',
                    'prev',
                    '‹',
                    '«',
                    '上一页',
                    '上一頁',
                    '前へ',
                  }.contains(label) ||
                  aria.contains('previous') ||
                  aria.contains('prev');
        if (matches) {
          candidate = link;
          break;
        }
      }
    }
    final href = candidate?.attributes['href'];
    if (href == null) return null;
    final uri = pageUri.resolve(href);
    return _isSource(uri) ? uri.toString() : null;
  }

  static int? _durationSeconds(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final numbers = parts.map(int.tryParse).toList();
    if (numbers.any((part) => part == null || part < 0)) return null;
    final minutes = numbers[numbers.length - 2]!;
    final seconds = numbers.last!;
    if (minutes > 59 || seconds > 59) return null;
    if (parts.length == 2) return minutes * 60 + seconds;
    return numbers.first! * 3600 + minutes * 60 + seconds;
  }

  static BaseOptions _defaultOptions() => BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 20),
  );

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _advanceSessionGeneration();
    final nativeAdapter = _nativeAdapter;
    final activeAdapter = _dio.httpClientAdapter;
    _browserAdapter = null;
    _mediaRoute = null;
    _dio.close(force: true);
    _metadataDio.close(force: true);
    if (!identical(activeAdapter, nativeAdapter)) {
      nativeAdapter.close(force: true);
    }
    super.dispose();
  }
}

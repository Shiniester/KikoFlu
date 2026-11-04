part of 'jable_client.dart';

class JableAccount extends ChangeNotifier {
  JableAccount._(this._client);

  static const favoritesUrl = 'https://jable.tv/my/favourites/videos/';
  static const _favoritesBlockId = 'list_videos_my_favourite_videos';
  static const _favoritesPager =
      'a.page-link[data-parameters*="from_my_fav_videos"]';

  final JableClient _client;
  bool _isLoggedIn = false;
  int _revision = 0;
  bool _disposed = false;

  bool get isLoggedIn => _isLoggedIn;
  int get revision => _revision;

  static bool isFavoritesUri(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host.toLowerCase() == 'jable.tv' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      (uri.path == '/my/favourites/videos' ||
          uri.path == '/my/favourites/videos/');

  static bool hasFavoritesList(Document document) =>
      document.querySelector('#$_favoritesBlockId') != null;

  void _sessionChanged() {
    _isLoggedIn = false;
    _changed();
  }

  void _setLoggedIn(bool value) {
    if (_disposed || value == _isLoggedIn) return;
    _isLoggedIn = value;
    _changed();
  }

  void _favoritesChanged() => _changed();

  void _changed() {
    if (_disposed) return;
    _revision++;
    notifyListeners();
  }

  Future<bool> checkLogin() async {
    await _client._prepareOnlineAccess();
    if (!_hasSession) {
      _setLoggedIn(false);
      return false;
    }

    final uri = Uri.parse(favoritesUrl);
    final generation = _client._generation;
    final document = await _client._loadDocument(uri);
    _client._ensureGeneration(generation, uri);
    if (hasFavoritesList(document)) {
      _setLoggedIn(true);
      return true;
    }
    if (_isLoginPage(document, uri)) {
      _setLoggedIn(false);
      return false;
    }
    throw VideoSourceException(
      'Jable returned an invalid favorites page.',
      sourceKey: _client.sourceKey,
      sourceUrl: uri.toString(),
    );
  }

  ({String id, bool selected})? _favoriteControl(Document document) {
    final button = document.querySelector('.video-info button.btn-action.fav');
    final id = button?.attributes['data-fav-video-id']?.trim();
    if (id == null || id.isEmpty) return null;
    return (id: id, selected: button!.classes.contains('active'));
  }

  Future<void> setVideoFavorite(VideoDetails details, bool favorite) async {
    final videoUri = _videoUri(details);
    await _client._prepareOnlineAccess();
    final generation = _client._generation;
    if (!await checkLogin()) {
      throw JableLoginRequiredException(sourceUrl: videoUri.toString());
    }
    _client._ensureGeneration(generation, videoUri);
    final sourceId = details.sourceId?.trim();
    if (sourceId == null || sourceId.isEmpty) {
      throw VideoSourceException(
        'Jable did not provide a favorite control for this video.',
        sourceKey: _client.sourceKey,
        sourceUrl: videoUri.toString(),
      );
    }
    final uri = videoUri.replace(
      queryParameters: {
        'mode': 'async',
        'format': 'json',
        'action': favorite ? 'add_to_favourites' : 'delete_from_favourites',
        'video_id': sourceId,
        'video_ids[]': sourceId,
        'fav_type': '0',
        'playlist_id': '0',
      },
    );
    final Response<String> response;
    try {
      response = await _client._dio.getUri<String>(
        uri,
        cancelToken: _client._sessionCancelToken,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {
            'Accept': 'application/json, text/javascript, */*; q=0.01',
            'User-Agent': _client._userAgent,
            'X-Requested-With': 'XMLHttpRequest',
            if (_client._cookie?.isNotEmpty == true) 'Cookie': _client._cookie!,
          },
        ),
      );
    } on DioException catch (error) {
      _client._ensureGeneration(generation, videoUri);
      if (error.error is JableVerificationRequiredException) {
        throw JableVerificationRequiredException(
          sourceUrl: videoUri.toString(),
        );
      }
      throw VideoSourceException(
        'Jable could not change this video favorite.',
        sourceKey: _client.sourceKey,
        sourceUrl: videoUri.toString(),
      );
    } on JableVerificationRequiredException {
      _client._ensureGeneration(generation, videoUri);
      throw JableVerificationRequiredException(sourceUrl: videoUri.toString());
    } on VideoSourceException catch (error) {
      _client._ensureGeneration(generation, videoUri);
      throw VideoSourceException(
        error.message,
        sourceKey: _client.sourceKey,
        sourceUrl: videoUri.toString(),
      );
    }
    _client._ensureGeneration(generation, videoUri);

    final status = response.statusCode ?? 0;
    final body = response.data ?? '';
    if (_client._looksLikeChallenge(body)) {
      throw JableVerificationRequiredException(sourceUrl: videoUri.toString());
    }
    final document = html_parser.parse(body);
    if (status == HttpStatus.unauthorized || _isLoginPage(document, videoUri)) {
      _setLoggedIn(false);
      throw JableLoginRequiredException(sourceUrl: videoUri.toString());
    }
    if (status >= 300 && status < 400) {
      final location = response.headers.value(HttpHeaders.locationHeader);
      final sourceRedirect = location == null
          ? null
          : _client._directoryUrl(videoUri, location);
      if (sourceRedirect != null) {
        final redirectUri = Uri.parse(sourceRedirect);
        if (_isLoginUrl(redirectUri)) {
          _setLoggedIn(false);
          throw JableLoginRequiredException(sourceUrl: videoUri.toString());
        }
      }
      throw VideoSourceException(
        'Jable redirected the favorite request.',
        sourceKey: _client.sourceKey,
        sourceUrl: videoUri.toString(),
      );
    }
    if (status < 200 || status >= 300) {
      throw VideoSourceException(
        'Jable returned HTTP $status.',
        sourceKey: _client.sourceKey,
        sourceUrl: videoUri.toString(),
      );
    }

    final Object? result;
    try {
      result = jsonDecode(body);
    } on FormatException catch (error) {
      throw VideoSourceException(
        'Jable did not confirm the favorite change.',
        sourceKey: _client.sourceKey,
        sourceUrl: videoUri.toString(),
        cause: error,
      );
    }
    if (result is Map && result['status'] == 'success') {
      _favoritesChanged();
      return;
    }
    if (_isAuthenticationFailure(result)) {
      _setLoggedIn(false);
      throw JableLoginRequiredException(sourceUrl: videoUri.toString());
    }
    throw VideoSourceException(
      'Jable did not confirm the favorite change.',
      sourceKey: _client.sourceKey,
      sourceUrl: videoUri.toString(),
    );
  }

  Future<List<VideoItem>> searchFavorites(
    String query, {
    bool Function()? isCurrent,
  }) async {
    final results = <VideoItem>[];
    if (isCurrent?.call() == false) return results;
    await _client._prepareOnlineAccess();
    if (!_hasSession) {
      _setLoggedIn(false);
      throw const JableLoginRequiredException(sourceUrl: favoritesUrl);
    }

    final generation = _client._generation;
    var uri = Uri.parse(favoritesUrl);
    final visited = <String>{uri.toString()};
    final seen = <String>{};
    final needle = query.trim().toLowerCase();

    while (true) {
      if (isCurrent?.call() == false) break;
      final page = await _client.browse(uri.toString());
      _client._ensureGeneration(generation, Uri.parse(page.url));
      if (isCurrent?.call() == false) break;
      for (final video in page.videos) {
        if (seen.add(video.id) &&
            (needle.isEmpty || video.title.toLowerCase().contains(needle))) {
          results.add(video);
        }
      }
      final next = page.nextUrl == null ? null : Uri.tryParse(page.nextUrl!);
      if (next == null ||
          !isFavoritesUri(next) ||
          isCurrent?.call() == false ||
          !visited.add(next.toString())) {
        break;
      }
      uri = next;
    }
    return results;
  }

  Future<void> logout() async {
    await _client._prepareOnlineAccess();
    if (!_hasSession) {
      _setLoggedIn(false);
      throw const JableLoginRequiredException(sourceUrl: favoritesUrl);
    }

    final generation = _client._generation;
    final favoritesUri = Uri.parse(favoritesUrl);
    final document = await _client._loadDocument(favoritesUri);
    _client._ensureGeneration(generation, favoritesUri);
    if (!hasFavoritesList(document)) {
      if (_isLoginPage(document, favoritesUri)) {
        _setLoggedIn(false);
        throw const JableLoginRequiredException(sourceUrl: favoritesUrl);
      }
      throw VideoSourceException(
        'Jable returned an invalid favorites page.',
        sourceKey: _client.sourceKey,
        sourceUrl: favoritesUrl,
      );
    }
    _setLoggedIn(true);

    final logoutUri = _findLogoutUri(document, favoritesUri);
    if (logoutUri == null) {
      throw VideoSourceException(
        'Jable did not expose a sign-out action on the signed-in page.',
        sourceKey: _client.sourceKey,
        sourceUrl: favoritesUrl,
      );
    }
    try {
      await _client._loadDocument(logoutUri);
    } on DioException {
      throw VideoSourceException(
        'Jable could not sign out the account.',
        sourceKey: _client.sourceKey,
        sourceUrl: favoritesUrl,
      );
    } on JableVerificationRequiredException {
      throw const JableVerificationRequiredException(sourceUrl: favoritesUrl);
    } on VideoSourceException catch (error) {
      throw VideoSourceException(
        error.message,
        sourceKey: _client.sourceKey,
        sourceUrl: favoritesUrl,
      );
    }
    _client._ensureGeneration(generation, favoritesUri);

    final confirmation = await _client._loadDocument(favoritesUri);
    _client._ensureGeneration(generation, favoritesUri);
    if (hasFavoritesList(confirmation)) {
      throw VideoSourceException(
        'Jable did not confirm that the account signed out.',
        sourceKey: _client.sourceKey,
        sourceUrl: favoritesUrl,
      );
    }
    if (!_isLoginPage(confirmation, favoritesUri)) {
      throw VideoSourceException(
        'Jable returned an invalid sign-out confirmation page.',
        sourceKey: _client.sourceKey,
        sourceUrl: favoritesUrl,
      );
    }
    await _client.clearSession(expectedGeneration: generation);
  }

  VideoCatalogPage _parseFavoritesPage(Document document, Uri uri) {
    final favorites = document.querySelector('#$_favoritesBlockId');
    final Element? fragment;
    if (favorites != null) {
      fragment = favorites;
      _setLoggedIn(true);
    } else if (_isLoginPage(document, uri)) {
      _setLoggedIn(false);
      throw JableLoginRequiredException(sourceUrl: uri.toString());
    } else if (_isFavoritesAjaxUri(uri)) {
      if (!_isLoggedIn) {
        throw VideoSourceException(
          'Jable returned an invalid favorites page.',
          sourceKey: _client.sourceKey,
          sourceUrl: uri.toString(),
        );
      }
      if (_hasPageShell(document)) {
        throw VideoSourceException(
          'Jable returned an invalid favorites page.',
          sourceKey: _client.sourceKey,
          sourceUrl: uri.toString(),
        );
      }
      fragment = document.querySelector('.list-videos');
      final hasFavoritesPaging =
          document.querySelector(_favoritesPager) != null;
      if (fragment == null && !hasFavoritesPaging) {
        throw VideoSourceException(
          'Jable returned an invalid favorites page.',
          sourceKey: _client.sourceKey,
          sourceUrl: uri.toString(),
        );
      }
      _setLoggedIn(true);
    } else {
      throw VideoSourceException(
        'Jable returned an invalid favorites page.',
        sourceKey: _client.sourceKey,
        sourceUrl: uri.toString(),
      );
    }

    final scopedHtml = fragment?.outerHtml ?? document.body?.innerHtml ?? '';
    final scopedDocument = html_parser.parse(scopedHtml);
    final requestedPage =
        int.tryParse(uri.queryParameters['from_my_fav_videos'] ?? '') ?? 1;
    final currentPage =
        _client._activePage(scopedDocument) ??
        (requestedPage > 0 ? requestedPage : 1);
    var lastPage = currentPage;
    final pageParameter = RegExp(
      r'''from_my_fav_videos["']?\s*[:=]\s*["']?(\d+)''',
    );
    for (final link in document.querySelectorAll(_favoritesPager)) {
      final match = pageParameter.firstMatch(
        link.attributes['data-parameters'] ?? '',
      );
      final page = int.tryParse(match?.group(1) ?? '');
      if (page != null && page > lastPage) lastPage = page;
    }
    return VideoCatalogPage(
      title: _client._pageTitle(document, uri),
      url: uri.toString(),
      videos: _client._parseVideos(scopedDocument, uri),
      nextUrl: currentPage < lastPage
          ? _favoritesPageUrl(currentPage + 1)
          : null,
      previousUrl: currentPage > 1 ? _favoritesPageUrl(currentPage - 1) : null,
      currentPage: currentPage,
      jumpMaxPage: lastPage > 1 ? lastPage : null,
      pageUrlBuilder: _favoritesPageUrl,
    );
  }

  static String _favoritesPageUrl(int page) {
    if (page < 1) throw ArgumentError.value(page, 'page');
    if (page == 1) return favoritesUrl;
    return Uri.parse(favoritesUrl)
        .replace(
          queryParameters: {
            'mode': 'async',
            'function': 'get_block',
            'block_id': _favoritesBlockId,
            'fav_type': '0',
            'playlist_id': '0',
            'sort_by': '',
            'from_my_fav_videos': '$page',
          },
        )
        .toString();
  }

  Uri? _findLogoutUri(Document document, Uri base) {
    for (final element in document.querySelectorAll('[href], [data-href]')) {
      for (final attribute in ['href', 'data-href']) {
        final href = _client._directoryUrl(base, element.attributes[attribute]);
        if (href == null) continue;
        final uri = Uri.parse(href);
        if (_isLogoutUrl(uri)) return uri;
      }
    }
    return null;
  }

  Uri _videoUri(VideoDetails details) {
    final pageUrl = Uri.tryParse(details.video.pageUrl);
    if (details.video.sourceKey != _client.sourceKey || pageUrl == null) {
      throw VideoSourceException(
        'Favorite changes require a Jable video page.',
        sourceKey: _client.sourceKey,
        sourceUrl: details.video.pageUrl,
      );
    }
    final uri = _client._sourceUri(pageUrl);
    final segments = _client._segments(uri);
    if (segments.length != 2 || segments.first != 'videos') {
      throw VideoSourceException(
        'Favorite changes require a Jable video page.',
        sourceKey: _client.sourceKey,
        sourceUrl: uri.toString(),
      );
    }
    return uri;
  }

  bool get _hasSession =>
      _client._cookie?.isNotEmpty == true || _client._browserAdapter != null;

  bool _isFavoritesAjaxUri(Uri uri) =>
      isFavoritesUri(uri) &&
      uri.queryParameters['mode'] == 'async' &&
      uri.queryParameters['function'] == 'get_block' &&
      uri.queryParameters['block_id'] == _favoritesBlockId;

  bool _isLoginPage(Document document, Uri base) {
    if (document.querySelector('form input[type="password"]') != null) {
      return true;
    }
    for (final element in document.querySelectorAll('[href], [data-href]')) {
      for (final attribute in ['href', 'data-href']) {
        final href = _client._directoryUrl(base, element.attributes[attribute]);
        if (href != null && _isLoginUrl(Uri.parse(href))) return true;
      }
    }
    return false;
  }

  bool _hasPageShell(Document document) =>
      document.querySelector('head title')?.text.trim().isNotEmpty == true ||
      document.querySelector('header, .header, #header') != null;

  bool _isLogoutUrl(Uri uri) =>
      uri.path == '/logout' ||
      uri.path == '/logout/' ||
      uri.queryParameters['action'] == 'logout';

  bool _isLoginUrl(Uri uri) => uri.pathSegments.any(
    (segment) =>
        const {'login', 'signin', 'sign-in'}.contains(segment.toLowerCase()),
  );

  bool _isAuthenticationFailure(Object? result) {
    final text = result is Map
        ? result.values.map((value) => '$value').join(' ').toLowerCase()
        : '$result'.toLowerCase();
    return RegExp(
      r'(not\s+logged|must\s+be\s+logged|login\s+required|please\s+log\s*in|sign[\s-]*in\s+required|unauthenticated|authentication\s+required)',
    ).hasMatch(text);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

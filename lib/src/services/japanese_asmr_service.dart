import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import '../models/japanese_asmr_browse.dart';
import '../models/search_query.dart';
import '../models/search_type.dart';
import '../models/sort_options.dart';
import 'proxy_config.dart';

class JapaneseAsmrVerificationRequiredException implements Exception {
  const JapaneseAsmrVerificationRequiredException();

  static const marker = '[jp-asmr-verification-required]';

  @override
  String toString() => marker;
}

class _JapaneseAsmrChapter {
  const _JapaneseAsmrChapter({required this.title, required this.startTimeMs});

  final String title;
  final int startTimeMs;
}

/// The public Japanese ASMR catalog is HTML, independent of Kikoeru accounts.
class JapaneseAsmrService {
  static final instance = JapaneseAsmrService();
  static final website = Uri.parse('https://japaneseasmr.com/');
  static const _verificationChannel = MethodChannel(
    'com.meteor.kikoeruflutter/japanese_asmr',
  );
  static const _sitePageSize = 14;
  static Future<void>? _browserQueue;
  static int _nextBrowserRequestId = 0;
  final Dio _dio;
  Uri? _verificationUri;
  bool _browserVerified = false;
  Response<String>? _verifiedPage;
  (ProxyMode, String?)? _verifiedProxy;
  int? _lastPostId;
  Document? _lastDetail;
  DateTime? _lastRead;

  JapaneseAsmrService({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 20);
    _dio.options.receiveTimeout = const Duration(seconds: 25);
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          request.headers.removeWhere(
            (key, _) =>
                const ['authorization', 'cookie'].contains(key.toLowerCase()),
          );
          handler.next(request);
        },
      ),
    );
  }

  Future<Response<String>> _get(
    Uri uri, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    try {
      final useBrowser = _browserVerified && _isSiteUri(uri);
      final response = useBrowser
          ? await Future.any<Response<String>>([
              _withBrowser(() => _readBrowser(uri, cancelToken)),
              if (cancelToken != null)
                cancelToken.whenCancel.then((error) => throw error),
            ])
          : await _dio.get<String>(
              uri.toString(),
              options: Options(
                responseType: ResponseType.plain,
                headers: headers,
              ),
              cancelToken: cancelToken,
            );
      if (_isCloudflareChallenge(response.headers, response.data)) {
        _requireVerification(uri);
      }
      if (useBrowser &&
          (response.statusCode! < 200 || response.statusCode! >= 300)) {
        throw DioException.badResponse(
          statusCode: response.statusCode!,
          requestOptions: response.requestOptions,
          response: response,
        );
      }
      return response;
    } on DioException catch (error) {
      final response = error.response;
      if (response != null &&
          _isCloudflareChallenge(response.headers, response.data)) {
        _requireVerification(uri);
      }
      rethrow;
    }
  }

  static bool _isSiteUri(Uri uri) =>
      uri.scheme == website.scheme &&
      uri.host == website.host &&
      uri.port == website.port &&
      uri.userInfo.isEmpty;

  static Future<T> _withBrowser<T>(Future<T> Function() action) async {
    final previous = _browserQueue;
    final done = Completer<void>();
    _browserQueue = done.future;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      if (identical(_browserQueue, done.future)) _browserQueue = null;
      done.complete();
    }
  }

  Response<String> _browserResponse(Map<dynamic, dynamic>? result) {
    final data = result?['data'];
    final urlValue = result?['url'];
    final url = urlValue is String ? Uri.tryParse(urlValue) : null;
    final status = result?['statusCode'];
    final headers = result?['headers'];
    if (data is! String ||
        url == null ||
        !url.hasScheme ||
        !_isSiteUri(url) ||
        status is! int ||
        status < 200 ||
        status > 599 ||
        headers is! Map ||
        headers.entries.any(
          (entry) => entry.key is! String || entry.value is! String,
        )) {
      throw PlatformException(
        code: 'invalid_response',
        message: 'Invalid site browser response.',
      );
    }
    return Response<String>(
      data: data,
      statusCode: status,
      headers: Headers.fromMap(
        headers.map((key, value) => MapEntry(key as String, [value as String])),
      ),
      requestOptions: RequestOptions(path: url.toString()),
    );
  }

  Future<Response<String>> _readBrowser(
    Uri uri,
    CancelToken? cancelToken,
  ) async {
    if (cancelToken?.cancelError case final error?) throw error;
    final verifiedPage = _verifiedPage;
    if (_verifiedProxy != (ProxyConfig.mode, ProxyConfig.httpsProxyUrl)) {
      _verifiedPage = null;
    } else if (verifiedPage?.requestOptions.uri == uri) {
      _verifiedPage = null;
      return verifiedPage!;
    }

    final id = _nextBrowserRequestId++;
    var finished = false;
    unawaited(
      cancelToken?.whenCancel.then((_) async {
        if (!finished) {
          try {
            await _verificationChannel.invokeMethod<void>('cancel', {'id': id});
          } on PlatformException {
            // The read can finish while cancellation is being delivered.
          }
        }
      }),
    );
    try {
      final result = await _verificationChannel
          .invokeMapMethod<String, dynamic>('read', {
            'id': id,
            'url': uri.toString(),
            'proxyMode': ProxyConfig.mode.name,
            'proxyAddress': ProxyConfig.httpsProxyUrl,
          });
      if (cancelToken?.cancelError case final error?) throw error;
      return _browserResponse(result);
    } on PlatformException catch (error) {
      if (cancelToken?.cancelError case final cancellation?) throw cancellation;
      if (error.code == 'verification_required') _requireVerification(uri);
      throw DioException(
        requestOptions: RequestOptions(path: uri.toString()),
        type: error.code == 'timeout'
            ? DioExceptionType.receiveTimeout
            : DioExceptionType.connectionError,
        error: error,
        message: error.message,
      );
    } finally {
      finished = true;
    }
  }

  Never _requireVerification(Uri uri) {
    if (_isSiteUri(uri)) {
      _verificationUri = uri;
    }
    throw const JapaneseAsmrVerificationRequiredException();
  }

  bool _isCloudflareChallenge(Headers headers, Object? data) =>
      headers.value('cf-mitigated')?.trim().toLowerCase() == 'challenge' ||
      (data is String &&
          (data.contains('window._cf_chl_opt') ||
              data.contains('/orchestrate/chl_page/')));

  Future<bool> verifyAccess({
    required String title,
    required String closeLabel,
  }) => _withBrowser(() async {
    final uri = _verificationUri ?? website;
    final proxy = (ProxyConfig.mode, ProxyConfig.httpsProxyUrl);
    final result = await _verificationChannel
        .invokeMapMethod<String, dynamic>('verify', {
          'url': uri.toString(),
          'proxyMode': proxy.$1.name,
          'proxyAddress': proxy.$2,
          'title': title,
          'closeLabel': closeLabel,
        });
    if (result == null) return false;
    final cookie = result['cookie'];
    final userAgent = result['userAgent'];
    if (cookie is! String ||
        userAgent is! String ||
        userAgent.trim().isEmpty ||
        !RegExp(r'^cf_clearance=[^;\r\n]+$').hasMatch(cookie)) {
      return false;
    }
    final response = _browserResponse(result);
    if (response.statusCode != 200 ||
        _isCloudflareChallenge(response.headers, response.data)) {
      throw PlatformException(
        code: 'verification_failed',
        message: 'Site browser access is still challenged.',
      );
    }
    _browserVerified = true;
    _verifiedPage = response;
    _verifiedProxy = proxy;
    _verificationUri = null;
    return true;
  });

  Future<Map<String, dynamic>> getWorks({
    required int page,
    required int pageSize,
    AgeRating ageRating = AgeRating.all,
    JapaneseAsmrSortOption? sort,
    SortDirection direction = SortDirection.desc,
    JapaneseAsmrPeriod period = JapaneseAsmrPeriod.week,
    int? archiveYear,
    int? archiveMonth,
    CancelToken? cancelToken,
  }) => _list(
    page: page,
    pageSize: pageSize,
    ageRating: ageRating,
    sort: sort,
    direction: direction,
    period: period,
    archiveYear: archiveYear,
    archiveMonth: archiveMonth,
    cancelToken: cancelToken,
  );

  Future<Map<String, dynamic>> searchWorks({
    required String keyword,
    required int page,
    required int pageSize,
    List<SearchCondition> conditions = const [],
    CancelToken? cancelToken,
  }) async {
    final filters = conditions
        .where(
          (condition) =>
              condition.type == SearchType.tag ||
              condition.type == SearchType.va ||
              condition.type == SearchType.circle,
        )
        .toList();
    for (final filter in filters) {
      final path = _catalogPath(filter.sourcePath);
      if (path.pathSegments.first !=
          (filter.type == SearchType.circle ? 'category' : 'tag')) {
        throw ArgumentError('Japanese ASMR catalog type does not match path');
      }
    }
    if (filters.isEmpty) {
      return _list(
        page: page,
        pageSize: pageSize,
        keyword: keyword,
        cancelToken: cancelToken,
      );
    }
    if (keyword.trim().isEmpty &&
        filters.every((filter) => !filter.isExclude) &&
        (filters.length == 1 ||
            filters.every((filter) => filter.type != SearchType.circle))) {
      final prefix = filters.first.type == SearchType.circle
          ? 'category'
          : 'tag';
      // Only the separator is literal: percent-encoding '+' breaks the archive.
      final slugs = filters.map(
        (filter) => Uri.encodeComponent(
          _catalogPath(filter.sourcePath).pathSegments[1],
        ),
      );
      return _list(
        page: page,
        pageSize: pageSize,
        archivePath: '/$prefix/${slugs.join('+')}/',
        cancelToken: cancelToken,
      );
    }
    return _filteredList(
      keyword: keyword,
      filters: filters,
      page: page,
      pageSize: pageSize,
      cancelToken: cancelToken,
    );
  }

  Future<List<Map<String, dynamic>>> getSearchCatalog(
    SearchType type, {
    CancelToken? cancelToken,
  }) async {
    final directory = switch (type) {
      SearchType.tag => 'tags',
      SearchType.va => 'cv',
      SearchType.circle => 'circles',
      _ => throw ArgumentError.value(type, 'type'),
    };
    final document = html.parse(
      (await _get(
        website.resolve('/$directory/'),
        cancelToken: cancelToken,
      )).data,
    );
    final entries = <String, Map<String, dynamic>>{};
    for (final link in document.querySelectorAll(
      '.entry-content .tag-groups-tag a[href]',
    )) {
      final uri = website.resolve(link.attributes['href']!);
      final name = link.querySelector('.tag-groups-label')?.text.trim();
      if (uri.scheme != website.scheme ||
          uri.host != website.host ||
          name == null ||
          name.isEmpty) {
        continue;
      }
      final path = uri.path;
      final expected = type == SearchType.circle ? 'category' : 'tag';
      if (uri.pathSegments.length != 3 ||
          uri.pathSegments.first != expected ||
          uri.pathSegments[1].isEmpty ||
          uri.pathSegments.last.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        continue;
      }
      final count = int.tryParse(
        (link.attributes['title'] ?? '').replaceAll(RegExp(r'[^0-9]'), ''),
      );
      entries[path] = {
        'name': name,
        'sourcePath': path,
        if (count != null) 'count': count,
      };
    }
    if (entries.isEmpty) {
      throw const FormatException(
        'Japanese ASMR search catalog is unavailable',
      );
    }
    return entries.values.toList()..sort(
      (a, b) =>
          ((b['count'] as int?) ?? 0).compareTo((a['count'] as int?) ?? 0),
    );
  }

  static Uri _catalogPath(String? value) {
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment ||
        !value!.startsWith('/') ||
        uri.pathSegments.length != 3 ||
        !const ['tag', 'category'].contains(uri.pathSegments.first) ||
        uri.pathSegments[1].isEmpty ||
        uri.pathSegments[1].contains('/') ||
        uri.pathSegments.last.isNotEmpty) {
      throw ArgumentError.value(
        value,
        'sourcePath',
        'Invalid Japanese ASMR catalog path',
      );
    }
    return uri;
  }

  Uri _listUri(
    int page, {
    String? keyword,
    String? archivePath,
    Map<String, String>? queryParameters,
  }) {
    final uri = keyword != null && keyword.isNotEmpty
        ? website.replace(
            pathSegments: [
              'search',
              keyword,
              if (page > 1) ...['page', '$page'],
              '',
            ],
          )
        : website.resolve(
            '${archivePath ?? '/'}${page > 1 ? 'page/$page/' : ''}',
          );
    return queryParameters == null || queryParameters.isEmpty
        ? uri
        : uri.replace(queryParameters: queryParameters);
  }

  int _lastPage(Document document) => document
      .querySelectorAll('.page-numbers')
      .map(
        (number) => int.tryParse(number.text.replaceAll(',', '').trim()) ?? 1,
      )
      .fold(1, math.max);

  List<Element> _cards(Document document) {
    final cards = document.querySelectorAll('li.site-archive-post');
    if (cards.isEmpty &&
        document.querySelector('#site-main, .site-main') == null) {
      throw const FormatException('Japanese ASMR catalog is unavailable');
    }
    return cards;
  }

  Future<Map<String, dynamic>> _filteredList({
    required String keyword,
    required List<SearchCondition> filters,
    required int page,
    required int pageSize,
    CancelToken? cancelToken,
  }) async {
    if (page < 1 || pageSize < 1) throw ArgumentError('Invalid page');
    final documents = <Uri, Document>{};
    Future<Document> read(Uri uri) async => documents[uri] ??= html.parse(
      (await _get(uri, cancelToken: cancelToken)).data,
    );
    final identities = <String>[];
    String? seedPath;
    var seedPages = 1 << 30;
    for (final filter in filters) {
      final uri = website.resolve(filter.sourcePath!);
      final document = await read(uri);
      final prefix = filter.type == SearchType.circle ? 'category-' : 'tag-';
      final identity = document.body?.classes.where(
        (name) => name.startsWith(prefix),
      );
      if (identity == null || identity.isEmpty) {
        throw const FormatException(
          'Japanese ASMR classification is unavailable',
        );
      }
      identities.add(identity.first);
      if (!filter.isExclude && _lastPage(document) < seedPages) {
        seedPath = filter.sourcePath;
        seedPages = _lastPage(document);
      }
    }
    final start = (page - 1) * pageSize;
    final matches = <Map<String, dynamic>>[];
    var matchedCount = 0;
    var sitePage = 1;
    var hasNext = true;
    while (hasNext && matchedCount <= start + pageSize) {
      final uri = _listUri(sitePage, keyword: keyword, archivePath: seedPath);
      final document =
          documents.remove(uri) ??
          html.parse((await _get(uri, cancelToken: cancelToken)).data);
      for (final card in _cards(document)) {
        if (!Iterable<int>.generate(filters.length).every(
          (index) =>
              card.classes.contains(identities[index]) !=
              filters[index].isExclude,
        )) {
          continue;
        }
        final link = card.querySelector('h2.entry-title a[href]');
        final id = link == null
            ? null
            : _postId(website.resolve(link.attributes['href']!));
        if (id != null && link!.text.trim().isNotEmpty) {
          if (matchedCount >= start && matches.length < pageSize) {
            matches.add(_work(card, id, link.text.trim()));
          }
          matchedCount++;
        }
      }
      hasNext = document.querySelector('a.next.page-numbers') != null;
      sitePage++;
    }
    return {
      'works': matches,
      'pagination': {
        'currentPage': page,
        'pageSize': pageSize,
        'totalCount': hasNext ? null : matchedCount,
        'hasMore': hasNext || matchedCount > start + pageSize,
      },
    };
  }

  Future<Map<String, dynamic>> _list({
    required int page,
    required int pageSize,
    String? keyword,
    String? archivePath,
    AgeRating ageRating = AgeRating.all,
    JapaneseAsmrSortOption? sort,
    SortDirection direction = SortDirection.desc,
    JapaneseAsmrPeriod period = JapaneseAsmrPeriod.week,
    int? archiveYear,
    int? archiveMonth,
    CancelToken? cancelToken,
  }) async {
    if (page < 1 || pageSize < 1) throw ArgumentError('Invalid page');
    if ((period == JapaneseAsmrPeriod.archiveYear ||
            period == JapaneseAsmrPeriod.archiveMonth) &&
        archiveYear == null) {
      throw ArgumentError('Archive period requires a year');
    }
    if (period == JapaneseAsmrPeriod.archiveMonth &&
        (archiveMonth == null || archiveMonth < 1 || archiveMonth > 12)) {
      throw ArgumentError('Archive month must be between 1 and 12');
    }
    final periodArchive = switch (period) {
      JapaneseAsmrPeriod.archiveYear => '/date/$archiveYear/',
      JapaneseAsmrPeriod.archiveMonth =>
        '/date/$archiveYear/${archiveMonth!.toString().padLeft(2, '0')}/',
      _ => null,
    };
    final ratingArchive = switch (ageRating) {
      AgeRating.all => null,
      AgeRating.general => '/category/rating/sfw/',
      AgeRating.r15 => '/category/rating/r-15/',
      AgeRating.adult => '/category/rating/maniax/',
    };
    final queryParameters = <String, String>{};
    if (sort != null) {
      queryParameters.addAll({
        'order': sort == JapaneseAsmrSortOption.popular
            ? SortDirection.desc.value
            : direction.value,
        'orderby': switch (sort) {
          JapaneseAsmrSortOption.date => 'date',
          JapaneseAsmrSortOption.title => 'title',
          JapaneseAsmrSortOption.comments => 'comment_count',
          JapaneseAsmrSortOption.popular => 'post_views',
        },
      });
      if ((sort == JapaneseAsmrSortOption.popular ||
              sort == JapaneseAsmrSortOption.comments) &&
          period.date != null) {
        queryParameters['date'] = period.date!;
      }
    }
    if (periodArchive != null) {
      queryParameters
        ..clear()
        ..addAll({'order': 'desc', 'orderby': 'post_views'});
    }
    final start = (page - 1) * pageSize;
    final first = start ~/ _sitePageSize + 1;
    final last = (start + pageSize - 1) ~/ _sitePageSize + 1;
    final works = <Map<String, dynamic>>[];
    var total = 0;
    var sitePage = first;
    while (true) {
      final uri = _listUri(
        sitePage,
        keyword: keyword,
        archivePath: periodArchive ?? archivePath ?? ratingArchive,
        queryParameters: queryParameters,
      );
      final document = html.parse(
        (await _get(uri, cancelToken: cancelToken)).data,
      );
      final cards = _cards(document);
      final batch = <Map<String, dynamic>>[];
      for (final card in cards) {
        final link = card.querySelector('h2.entry-title a');
        final href = link?.attributes['href'];
        if (href == null) continue;
        final id = _postId(website.resolve(href));
        if (id == null || link!.text.trim().isEmpty) continue;
        batch.add(_work(card, id, link.text.trim()));
      }
      if (sitePage <= last) works.addAll(batch);
      var lastPage = sitePage;
      for (final number in document.querySelectorAll('.page-numbers')) {
        final value = int.tryParse(number.text.replaceAll(',', '').trim());
        if (value != null) lastPage = math.max(lastPage, value);
      }
      final hasNext = document.querySelector('a.next.page-numbers') != null;
      if (!hasNext) {
        total = (sitePage - 1) * _sitePageSize + batch.length;
        break;
      }
      // Count actual tail items instead of assuming the last page is full.
      sitePage = sitePage < last
          ? sitePage + 1
          : math.max(lastPage, sitePage + 1);
    }
    final offset = start % _sitePageSize;
    return {
      'works': works.skip(offset).take(pageSize).toList(),
      'pagination': {
        'currentPage': page,
        'pageSize': pageSize,
        'totalCount': total,
      },
    };
  }

  Future<Document> _detail(
    int postId,
    bool forceRefresh, {
    CancelToken? cancelToken,
  }) async {
    if (postId <= 0) throw ArgumentError.value(postId, 'postId');
    if (!forceRefresh &&
        _lastPostId == postId &&
        _lastDetail != null &&
        DateTime.now().difference(_lastRead!) < const Duration(minutes: 1)) {
      return _lastDetail!;
    }
    final document = html.parse(
      (await _get(website.resolve('/$postId/'), cancelToken: cancelToken)).data,
    );
    if (document.querySelector('h1.page-title') == null) {
      throw const FormatException('Japanese ASMR work is unavailable');
    }
    _lastPostId = postId;
    _lastDetail = document;
    _lastRead = DateTime.now();
    return document;
  }

  Future<Map<String, dynamic>> getWork(
    int postId, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    final document = await _detail(
      postId,
      forceRefresh,
      cancelToken: cancelToken,
    );
    final root =
        document.querySelector('#site-main, .site-main') ?? document.body!;
    return _work(
      root,
      postId,
      document.querySelector('h1.page-title')!.text.trim(),
    );
  }

  Map<String, dynamic> _work(Element root, int postId, String title) {
    final productId = RegExp(r'\b(?:RJ|BJ|VJ)\d+\b', caseSensitive: false)
        .firstMatch(root.querySelector('#work_title_jp')?.text ?? root.text)
        ?.group(0)
        ?.toUpperCase();
    final cover =
        root.querySelector('#img_cover')?.attributes['href'] ??
        _image(root.querySelector('.op-square img'));
    final images = root
        .querySelectorAll('.fotorama a[href]')
        .map((e) => _url(e.attributes['href']))
        .whereType<String>()
        .toSet()
        .toList();
    final categories = root.querySelectorAll(
      '.entry-tagline a[rel="category tag"]',
    );
    final circle = categories.where((e) {
      final href = e.attributes['href'] ?? '';
      return !href.contains('/rating/') && !href.contains('/requested/');
    });
    final voice =
        root.querySelector('#voice_actors')?.text ??
        RegExp(r'CV:\s*([^\n\r]+)').firstMatch(root.text)?.group(1);
    final tags = root.querySelectorAll('a[rel="tag"]');
    return {
      // Negative page IDs preserve legacy integer-keyed history and downloads.
      'id': -postId,
      'title': title,
      'source_id': productId ?? 'JP-$postId',
      'source_url': website.resolve('/$postId/').toString(),
      'cover_url': _url(cover),
      'name': circle.isEmpty ? null : circle.first.text.trim(),
      'release': root.querySelector('time[datetime]')?.attributes['datetime'],
      'vas': [
        if (voice != null)
          for (final name
              in voice.replaceFirst(RegExp(r'^CV:\s*'), '').split(','))
            if (name.trim().isNotEmpty)
              {'id': name.trim(), 'name': name.trim()},
      ],
      'tags': [
        // ASMR.ONE tag translations use positive IDs.
        for (var i = 0; i < tags.length; i++)
          {'id': -(i + 1), 'name': tags[i].text.trim()},
      ],
      'images': images,
      'description': root.querySelector('#jp-desc, #japaneseDesc')?.text.trim(),
    };
  }

  Future<List<dynamic>> getWorkTracks(
    int postId, {
    bool forceRefresh = false,
  }) async {
    final document = await _detail(postId, forceRefresh);
    final source =
        document.querySelector('#cleanp_audio source[src]') ??
        document.querySelector('#audio[src]');
    final stream = _url(source?.attributes['src']);
    if (stream == null) {
      throw const FormatException('Japanese ASMR audio source is unavailable');
    }
    final work = await getWork(postId);
    final productId = work['source_id'] as String;
    final download = document.querySelector('#downloadlink a[href]');
    final downloadUrl = _url(download?.attributes['href']);
    final images = work['images'] as List<String>;
    final chapters = _chapters(document);
    return [
      if (chapters.isEmpty)
        {
          'type': 'audio',
          'title': '$productId.m4a',
          'hash': 'jp-$postId-main',
          'mediaStreamUrl': stream,
          if (downloadUrl != null) 'mediaDownloadUrl': downloadUrl,
        }
      else
        for (var i = 0; i < chapters.length; i++)
          {
            'type': 'audio',
            'title': _chapterFileName(chapters[i].title, i + 1),
            'hash': 'jp-$postId-chapter-${chapters[i].startTimeMs}',
            'mediaStreamUrl': stream,
            'mediaDownloadUrl': stream,
            'startTimeMs': chapters[i].startTimeMs,
            'endTimeMs': i + 1 < chapters.length
                ? chapters[i + 1].startTimeMs
                : null,
            if (i + 1 < chapters.length)
              'duration':
                  (chapters[i + 1].startTimeMs - chapters[i].startTimeMs) /
                  1000,
          },
      for (var i = 0; i < images.length; i++)
        {
          'type': 'image',
          'title': Uri.decodeComponent(Uri.parse(images[i]).pathSegments.last),
          'hash': 'jp-$postId-image-$i',
          'mediaStreamUrl': images[i],
          'mediaDownloadUrl': images[i],
        },
    ];
  }

  static List<_JapaneseAsmrChapter> _chapters(Document document) {
    final playlist =
        document.querySelector('#plyr-chapter-playlist') ??
        document.querySelector('#basic-chapter-playlist');
    if (playlist == null) return const [];

    final chapters = <_JapaneseAsmrChapter>[];
    int? previousStartTimeMs;
    for (final link in playlist.querySelectorAll(
      'tr .chapter_title a[data-track-title][data-value]',
    )) {
      final title = link.attributes['data-track-title']?.trim();
      final seconds = num.tryParse(link.attributes['data-value']?.trim() ?? '');
      if (title == null ||
          title.isEmpty ||
          seconds == null ||
          !seconds.isFinite ||
          seconds < 0) {
        continue;
      }
      final startTimeMs = (seconds * 1000).round();
      if (previousStartTimeMs != null && startTimeMs <= previousStartTimeMs) {
        continue;
      }
      chapters.add(
        _JapaneseAsmrChapter(title: title, startTimeMs: startTimeMs),
      );
      previousStartTimeMs = startTimeMs;
    }
    return chapters;
  }

  static String _chapterFileName(String title, int chapterNumber) {
    final stem = title.replaceFirst(
      RegExp(r'\.(?:aac|mp3|m4a|wav|flac|ogg|opus)$', caseSensitive: false),
      '',
    );
    return '${chapterNumber}_$stem.aac';
  }

  Future<List<dynamic>> getRelatedWorks(int postId) async {
    final document = await _detail(postId, false);
    final seen = <int>{postId};
    final works = <Map<String, dynamic>>[];
    for (final item in document.querySelectorAll('.yarpp-related ul li')) {
      final link = item.querySelector('a[href]');
      final href = link?.attributes['href'];
      final title = link?.querySelector('.crp_title')?.text.trim();
      if (href == null || title == null || title.isEmpty) continue;
      final relatedId = _postId(website.resolve(href));
      if (relatedId == null || !seen.add(relatedId)) continue;

      final cover = _url(_image(link?.querySelector('img.crp_thumb')));
      final fileName = cover == null
          ? null
          : Uri.parse(cover).pathSegments.last;
      final sourceId = fileName == null
          ? null
          : RegExp(
              r'^((?:RJ|BJ|VJ)\d+)(?:_|\.|$)',
              caseSensitive: false,
            ).firstMatch(fileName)?.group(1)?.toUpperCase();
      works.add({
        'id': -relatedId,
        'title': title,
        'source_id': sourceId ?? 'JP-$relatedId',
        'source_url': website.resolve('/$relatedId/').toString(),
        'cover_url': cover,
      });
    }
    return works;
  }

  /// Resolves the site's download index and the host's public download button.
  /// Signed download addresses are resolved for each attempt, never persisted.
  Future<String> resolveDownloadUrl(
    String url, {
    CancelToken? cancelToken,
  }) async {
    var uri = Uri.parse(url);
    if (uri.host == website.host && uri.path == '/dlc.php') {
      final document = html.parse(
        (await _get(uri, cancelToken: cancelToken)).data,
      );
      final productId = uri.queryParameters['f'];
      final audioLinks = document
          .querySelectorAll('a[href]')
          .where(
            (e) => RegExp(
              r'\.(m4a|mp3|flac|opus)$',
              caseSensitive: false,
            ).hasMatch(e.text.trim()),
          )
          .toList();
      final fullWork = audioLinks.where(
        (e) =>
            e.text.trim().split('.').first.toUpperCase() ==
            productId?.toUpperCase(),
      );
      final link = fullWork.isNotEmpty
          ? fullWork.first
          : audioLinks.length == 1
          ? audioLinks.single
          : null;
      final href = link?.attributes['href'];
      if (href == null) {
        throw const FormatException(
          'Japanese ASMR full audio download is unavailable',
        );
      }
      uri = uri.resolve(href);
    }
    if (uri.host == 'buzzheavier.com' ||
        uri.host.endsWith('.buzzheavier.com')) {
      final page = await _get(uri, cancelToken: cancelToken);
      final document = html.parse(page.data);
      final path = document
          .querySelector('a.download-btn[hx-get]')
          ?.attributes['hx-get'];
      if (path == null) {
        throw const FormatException('Audio host download is unavailable');
      }
      final target = page.realUri.resolve(path);
      final response = await _get(
        target,
        headers: {'HX-Request': 'true', 'Referer': page.realUri.toString()},
        cancelToken: cancelToken,
      );
      final redirect = response.headers.value('HX-Redirect');
      if (redirect == null || _url(redirect) == null) {
        throw const FormatException('Audio host did not provide a download');
      }
      return target.resolve(redirect).toString();
    }
    if (_url(uri.toString()) == null || uri.path.endsWith('.m3u8')) {
      throw const FormatException('Not a downloadable audio file');
    }
    return uri.toString();
  }

  static int? _postId(Uri uri) {
    if (uri.host != website.host ||
        uri.pathSegments.where((s) => s.isNotEmpty).length != 1) {
      return null;
    }
    final id = int.tryParse(uri.pathSegments.first);
    return id != null && id > 0 ? id : null;
  }

  static String? _image(Element? element) =>
      element?.attributes['data-src'] ?? element?.attributes['src'];

  static String? _url(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final uri = website.resolve(value.trim());
    return const ['http', 'https'].contains(uri.scheme) && uri.host.isNotEmpty
        ? uri.toString()
        : null;
  }
}

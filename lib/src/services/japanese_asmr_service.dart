import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'proxy_config.dart';

class JapaneseAsmrVerificationRequiredException implements Exception {
  const JapaneseAsmrVerificationRequiredException();

  static const marker = '[jp-asmr-verification-required]';

  @override
  String toString() => marker;
}

/// The public Japanese ASMR catalog is HTML, independent of Kikoeru accounts.
class JapaneseAsmrService {
  static final instance = JapaneseAsmrService();
  static final website = Uri.parse('https://japaneseasmr.com/');
  static const _verificationChannel = MethodChannel(
    'com.meteor.kikoeruflutter/japanese_asmr',
  );
  static const _sitePageSize = 14;
  final Dio _dio;
  String? _verificationCookie;
  String? _verificationUserAgent;
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
          if (request.uri.scheme == 'https' &&
              request.uri.host == website.host) {
            if (_verificationCookie case final cookie?) {
              request.headers['Cookie'] = cookie;
            }
            if (_verificationUserAgent case final userAgent?) {
              request.headers['User-Agent'] = userAgent;
            }
          }
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
      final response = await _dio.get<String>(
        uri.toString(),
        options: Options(responseType: ResponseType.plain, headers: headers),
        cancelToken: cancelToken,
      );
      if (_isCloudflareChallenge(response.headers, response.data)) {
        throw const JapaneseAsmrVerificationRequiredException();
      }
      return response;
    } on DioException catch (error) {
      final response = error.response;
      if (response != null &&
          _isCloudflareChallenge(response.headers, response.data)) {
        throw const JapaneseAsmrVerificationRequiredException();
      }
      rethrow;
    }
  }

  bool _isCloudflareChallenge(Headers headers, Object? data) =>
      headers.value('cf-mitigated')?.trim().toLowerCase() == 'challenge' ||
      (data is String &&
          (data.contains('window._cf_chl_opt') ||
              data.contains('/orchestrate/chl_page/')));

  Future<bool> verifyAccess({
    required String title,
    required String closeLabel,
  }) async {
    final result = await _verificationChannel
        .invokeMapMethod<String, String>('verify', {
          'url': website.toString(),
          'proxyMode': ProxyConfig.mode.name,
          'proxyAddress': ProxyConfig.httpsProxyUrl,
          'title': title,
          'closeLabel': closeLabel,
        });
    if (result == null) return false;
    final cookie = result['cookie'];
    final userAgent = result['userAgent'];
    if (cookie == null ||
        userAgent == null ||
        userAgent.trim().isEmpty ||
        (cookie.isNotEmpty &&
            !RegExp(r'^cf_clearance=[^;\r\n]+$').hasMatch(cookie))) {
      return false;
    }
    _verificationCookie = cookie.isEmpty ? null : cookie;
    _verificationUserAgent = userAgent;
    return true;
  }

  Future<Map<String, dynamic>> getWorks({
    required int page,
    required int pageSize,
    CancelToken? cancelToken,
  }) => _list(page: page, pageSize: pageSize, cancelToken: cancelToken);

  Future<Map<String, dynamic>> searchWorks({
    required String keyword,
    required int page,
    required int pageSize,
    CancelToken? cancelToken,
  }) => _list(
    page: page,
    pageSize: pageSize,
    keyword: keyword,
    cancelToken: cancelToken,
  );

  Future<Map<String, dynamic>> _list({
    required int page,
    required int pageSize,
    String? keyword,
    CancelToken? cancelToken,
  }) async {
    if (page < 1 || pageSize < 1) throw ArgumentError('Invalid page');
    final start = (page - 1) * pageSize;
    final first = start ~/ _sitePageSize + 1;
    final last = (start + pageSize - 1) ~/ _sitePageSize + 1;
    final works = <Map<String, dynamic>>[];
    var total = 0;
    var sitePage = first;
    while (true) {
      final uri = keyword == null || keyword.isEmpty
          ? website.resolve(sitePage == 1 ? '/' : '/page/$sitePage/')
          : website.replace(
              pathSegments: [
                'search',
                keyword,
                if (sitePage > 1) ...['page', '$sitePage'],
                '',
              ],
            );
      final document = html.parse(
        (await _get(uri, cancelToken: cancelToken)).data,
      );
      final cards = document.querySelectorAll('li.site-archive-post');
      if (cards.isEmpty &&
          document.querySelector('#site-main, .site-main') == null) {
        throw const FormatException('Japanese ASMR catalog is unavailable');
      }
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
    return [
      {
        'type': 'audio',
        'title': '$productId.m4a',
        'hash': 'jp-$postId-main',
        'mediaStreamUrl': stream,
        if (downloadUrl != null) 'mediaDownloadUrl': downloadUrl,
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

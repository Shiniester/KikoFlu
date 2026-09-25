// Protocol adapted from PicaComic. MIT, Copyright (c) 2023 Nyne.
import '../comic_models.dart';
import '../../services/storage_service.dart';
import '../comic_source.dart';

class NhSource extends ComicSource {
  NhSource(super.http);
  @override
  bool get hasComments => true;
  @override
  String get key => 'nhentai';
  @override
  String get name => 'NHentai';
  @override
  String get website => 'https://nhentai.net';
  @override
  List<String> get searchSorts => [
    'date',
    'popular-today',
    'popular-week',
    'popular-month',
    'popular',
  ];
  Future<dynamic> _api(
    String path, {
    String method = 'GET',
    Object? data,
    bool refresh = true,
  }) async {
    final generation = http.sessionGeneration;
    try {
      return await http.json(
        '$website/api/v2/$path',
        method: method,
        data: data,
        headers: {
          'Referer': '$website/',
          if (http.token ?? http.cookieValue('access_token')
              case final String token)
            'Authorization': 'User $token',
        },
      );
    } on ComicSourceException catch (e) {
      final refreshToken = http.cookieValue('refresh_token');
      if (!refresh ||
          !e.loginRequired ||
          refreshToken == null ||
          !http.hasSession) {
        rethrow;
      }
      final session = await http.json(
        '$website/api/v2/auth/refresh',
        method: 'POST',
        data: {'refresh_token': refreshToken},
      );
      if (!http.hasSession || generation != http.sessionGeneration) rethrow;
      final cookies = <String, String>{};
      for (final part
          in (StorageService.getString('comic_nhentai_cookie') ?? '').split(
            ';',
          )) {
        final separator = part.indexOf('=');
        if (separator > 0) {
          cookies[part.substring(0, separator).trim()] = part
              .substring(separator + 1)
              .trim();
        }
      }
      if (session['refresh_token'] != null) {
        cookies['refresh_token'] = session['refresh_token'].toString();
      }
      await http.saveSession(
        token: session['access_token'],
        cookie: cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      );
      return _api(path, method: method, data: data, refresh: false);
    }
  }

  static String imageUrl(String path, {bool thumbnail = false}) =>
      path.startsWith('http')
      ? path
      : Uri.parse(
          thumbnail ? 'https://t.nhentai.net/' : 'https://i.nhentai.net/',
        ).resolve(path).toString();
  static Comic parseComic(Map<String, dynamic> c) {
    final title = c['title'];
    final thumbnail = c['cover'] is Map
        ? c['cover']['path']
        : c['thumbnail'] is Map
        ? c['thumbnail']['path']
        : c['thumbnail'];
    return Comic(
      source: 'nhentai',
      id: '${c['id']}',
      title: title is Map
          ? '${title['japanese'] ?? title['english'] ?? title['pretty'] ?? ''}'
          : '${c['japanese_title'] ?? c['english_title'] ?? ''}',
      cover: imageUrl('${thumbnail ?? ''}', thumbnail: true),
      tags: (c['tags'] as List? ?? [])
          .map((t) => '${t['type']}:${t['name']}')
          .toList(),
      chapters: [ComicChapter('${c['id']}', '1')],
      extra: {'pages': c['pages'] ?? []},
    );
  }

  ComicResult _result(dynamic data, int page) => ComicResult(
    (data['result'] as List)
        .map((c) => parseComic(Map<String, dynamic>.from(c)))
        .toList(),
    next: page < (data['num_pages'] as num? ?? page) ? '${page + 1}' : null,
    totalPages: (data['num_pages'] as num?)?.toInt(),
  );
  @override
  Future<ComicResult> search(
    String query, {
    String? cursor,
    String? sort,
  }) async {
    final page = int.parse(cursor ?? '1');
    return _result(
      await _api(
        'search?query=${Uri.encodeComponent(query.isEmpty ? ' ' : query)}&page=$page&sort=${sort ?? 'date'}',
      ),
      page,
    );
  }

  @override
  Future<Comic> details(String id) async =>
      parseComic(Map<String, dynamic>.from(await _api('galleries/$id')));
  @override
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter) async {
    final data = comic.extra['pages'] as List?;
    final pages = data != null && data.isNotEmpty
        ? data
        : (await details(comic.id)).extra['pages'] as List;
    return pages
        .map(
          (p) =>
              ComicPage(imageUrl(p['path']), headers: {'Referer': '$website/'}),
        )
        .toList();
  }

  @override
  Future<ComicResult> favorites({String? cursor}) async {
    final page = int.parse(cursor ?? '1');
    return _result(await _api('favorites?page=$page'), page);
  }

  @override
  Future<void> setFavorite(Comic comic, bool value) async {
    await _api(
      'galleries/${comic.id}/favorite',
      method: value ? 'POST' : 'DELETE',
    );
  }

  @override
  Future<List<ComicComment>> comments(Comic comic) async {
    final data = await _api('galleries/${comic.id}/comments');
    final list = data is List
        ? data
        : (data['comments'] ?? data['result'] ?? data['items'] ?? []) as List;
    return list
        .map<ComicComment>(
          (c) => ComicComment(
            '${c['poster']?['username'] ?? c['username'] ?? ''}',
            '${c['body'] ?? c['content'] ?? ''}',
          ),
        )
        .toList();
  }
}

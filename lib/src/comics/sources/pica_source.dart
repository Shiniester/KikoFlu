// Protocol adapted from PicaComic. MIT, Copyright (c) 2023 Nyne.
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../comic_models.dart';
import '../comic_source.dart';

class PicaSource extends ComicSource {
  PicaSource(super.http);
  @override
  bool get hasComments => true;
  @override
  String get key => 'picacg';
  @override
  String get name => 'Picacg';
  @override
  String get website => 'https://picaapi.picacomic.com';
  @override
  bool get hasPasswordLogin => true;
  @override
  List<String> get searchSorts => ['dd', 'da', 'ld', 'vd'];

  static String signature(
    String path,
    String nonce,
    String time,
    String method,
  ) {
    const apiKey = 'C69BAF41DA5ABD1FFEDC6D2FEA56B';
    const secret =
        '~d}\$Q7\$eIni=V)9\\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn';
    return Hmac(sha256, utf8.encode(secret))
        .convert(utf8.encode('$path$time$nonce$method$apiKey'.toLowerCase()))
        .toString();
  }

  Future<Map<String, dynamic>> _api(
    String path, {
    String method = 'GET',
    Object? data,
  }) async {
    final time = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final random = Random.secure();
    final nonce = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final response = await http.json(
      '$website/$path',
      method: method,
      data: data,
      headers: {
        'api-key': 'C69BAF41DA5ABD1FFEDC6D2FEA56B',
        'accept': 'application/vnd.picacomic.com.v1+json',
        'app-channel': '3',
        'authorization': http.token ?? '',
        'time': time,
        'nonce': nonce,
        'app-version': '2.2.1.3.3.4',
        'app-uuid': 'defaultUuid',
        'image-quality': 'original',
        'app-platform': 'android',
        'app-build-version': '45',
        'Content-Type': 'application/json; charset=UTF-8',
        'user-agent': 'okhttp/3.8.1',
        'version': 'v1.4.1',
        'signature': signature(path, nonce, time, method),
      },
    );
    if (response['code'] != null && response['code'] != 200) {
      throw ComicSourceException('${response['message'] ?? response['error']}');
    }
    return Map<String, dynamic>.from(response['data']);
  }

  static String media(dynamic m) {
    if (m == null) return '';
    final url = '${m['fileServer']}/static/${m['path']}';
    if (!url.contains('/tobeimg/')) return url;
    try {
      final uri = Uri.parse(url);
      final name = uri.pathSegments.last;
      final dot = name.lastIndexOf('.');
      final encoded = dot < 0 ? name : name.substring(0, dot);
      final decoded = utf8.decode(
        base64Url.decode(base64Url.normalize(encoded)),
      );
      return decoded.startsWith('http')
          ? decoded
          : '${uri.scheme}://${uri.authority}/$decoded';
    } on FormatException {
      return url;
    }
  }

  Comic _comic(dynamic c, {List<ComicChapter> chapters = const []}) => Comic(
    source: key,
    id: '${c['_id']}',
    title: c['title'] ?? '',
    cover: media(c['thumb']),
    description: c['description'] ?? '',
    tags: [
      ...List<String>.from(c['categories'] ?? []),
      ...List<String>.from(c['tags'] ?? []),
    ],
    chapters: chapters,
    extra: {
      'isFavorite': c['isFavourite'] ?? false,
      'likes': c['likesCount'],
      if (c['updated_at'] ?? c['created_at'] case final date?)
        'sourceDate': date,
    },
  );
  ComicResult _result(dynamic data, int page) {
    final pages = (data['pages'] as num?)?.toInt() ?? page;
    return ComicResult(
      (data['docs'] as List).map(_comic).toList(),
      next: page < pages ? '${page + 1}' : null,
      totalPages: pages,
    );
  }

  @override
  Future<void> login(String username, String password) async {
    final generation = http.sessionGeneration;
    final data = await _api(
      'auth/sign-in',
      method: 'POST',
      data: {'email': username, 'password': password},
    );
    if (generation != http.sessionGeneration) return;
    await http.saveSession(token: data['token']);
  }

  @override
  Future<ComicResult> explore({String? cursor}) async {
    final page = int.parse(cursor ?? '1');
    return _result((await _api('comics?page=$page&s=dd'))['comics'], page);
  }

  @override
  Future<ComicResult> search(
    String query, {
    String? cursor,
    String? sort,
  }) async {
    final page = int.parse(cursor ?? '1');
    return _result(
      (await _api(
        'comics/advanced-search?page=$page',
        method: 'POST',
        data: {'keyword': query, 'sort': sort ?? 'dd'},
      ))['comics'],
      page,
    );
  }

  @override
  Future<List<ComicCategory>> categories() async =>
      ((await _api('categories'))['categories'] as List)
          .where((c) => c['isWeb'] != true)
          .map((c) => ComicCategory(c['title'], c['title']))
          .toList();
  @override
  Future<ComicResult> category(ComicCategory category, {String? cursor}) async {
    final page = int.parse(cursor ?? '1');
    return _result(
      (await _api(
        'comics?page=$page&c=${Uri.encodeComponent(category.id)}&s=dd',
      ))['comics'],
      page,
    );
  }

  @override
  Future<Comic> details(String id) async {
    final data = (await _api('comics/$id'))['comic'];
    return _comic(data);
  }

  @override
  Future<List<ComicChapter>> chapters(Comic comic) async {
    final id = comic.id;
    final eps = <dynamic>[];
    for (var page = 1; ; page++) {
      final e = (await _api('comics/$id/eps?page=$page'))['eps'];
      eps.addAll(e['docs']);
      if (page >= (e['pages'] as num)) break;
    }
    eps.sort((a, b) => (a['order'] as num).compareTo(b['order'] as num));
    return eps.map((e) => ComicChapter('${e['order']}', e['title'])).toList();
  }

  @override
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter) async {
    final result = <ComicPage>[];
    for (var page = 1; ; page++) {
      final data = (await _api(
        'comics/${comic.id}/order/${chapter.id}/pages?page=$page',
      ))['pages'];
      result.addAll(
        (data['docs'] as List).map((p) => ComicPage(media(p['media']))),
      );
      if (page >= (data['pages'] as num)) break;
    }
    return result;
  }

  @override
  Future<ComicResult> favorites({String? cursor}) async {
    final page = int.parse(cursor ?? '1');
    return _result(
      (await _api('users/favourite?s=dd&page=$page'))['comics'],
      page,
    );
  }

  @override
  Future<void> setFavorite(Comic comic, bool value) async {
    final current = await details(comic.id);
    if (current.extra['isFavorite'] != value) {
      await _api('comics/${comic.id}/favourite', method: 'POST', data: {});
    }
  }

  @override
  Future<List<ComicComment>> comments(Comic comic) async {
    final data = (await _api('comics/${comic.id}/comments?page=1'))['comments'];
    return (data['docs'] as List)
        .map(
          (c) => ComicComment(
            '${c['_user']?['name'] ?? ''}',
            '${c['content'] ?? ''}',
            score: c['likesCount']?.toString(),
          ),
        )
        .toList();
  }
}

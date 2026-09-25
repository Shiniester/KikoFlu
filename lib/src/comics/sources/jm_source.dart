// Protocol adapted from PicaComic. MIT, Copyright (c) 2023 Nyne.
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import '../../services/storage_service.dart';
import '../comic_models.dart';
import '../comic_source.dart';

class JmSource extends ComicSource {
  JmSource(super.http);
  @override
  bool get hasComments => true;
  @override
  String get key => 'jmcomic';
  @override
  String get name => 'JMComic';
  @override
  String get website =>
      StorageService.getString('comic_jmcomic_endpoint') ??
      'https://www.cdntwice.org';
  String get imageHost =>
      StorageService.getString('comic_jmcomic_images') ??
      'https://cdn-msp.jmapiproxy3.cc';
  @override
  bool get hasPasswordLogin => true;
  @override
  List<String> get searchSorts => [
    'mr',
    'mv',
    'mv_m',
    'mv_w',
    'mv_t',
    'mp',
    'tf',
  ];
  static dynamic decrypt(String data, int time) {
    final key = Uint8List.fromList(
      utf8.encode(
        md5.convert(utf8.encode('${time}185Hcomic3PAPP7R')).toString(),
      ),
    );
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))
          ..init(
            false,
            PaddedBlockCipherParameters<KeyParameter, Null>(
              KeyParameter(key),
              null,
            ),
          );
    return jsonDecode(utf8.decode(cipher.process(base64Decode(data))));
  }

  Future<dynamic> _api(
    String path, {
    String method = 'GET',
    Object? data,
  }) async {
    final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final result = await http.json(
      '$website/$path',
      method: method,
      data: data,
      headers: {
        'token': md5
            .convert(utf8.encode('${time}18comicAPPContent'))
            .toString(),
        'tokenparam':
            '$time,${StorageService.getString('comic_jmcomic_version') ?? '2.0.11'}',
        'Authorization': 'Bearer',
        'Origin': 'https://localhost',
        'Referer': 'https://localhost/',
        'X-Requested-With': 'com.example.app',
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 10; K; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/138.0.0.0 Mobile Safari/537.36',
        if (method == 'POST')
          'Content-Type': 'application/x-www-form-urlencoded',
      },
    );
    if (result['code'] != null && result['code'] != 200) {
      throw ComicSourceException('${result['errorMsg'] ?? result['message']}');
    }
    return result['data'] is String
        ? decrypt(result['data'], time)
        : result['data'];
  }

  Comic _comic(dynamic c, {List<ComicChapter> chapters = const []}) => Comic(
    source: key,
    id: '${c['id']}',
    title: '${c['name'] ?? c['title'] ?? ''}',
    cover: '$imageHost/media/albums/${c['id']}_3x4.jpg',
    description: '${c['description'] ?? ''}',
    tags: List<String>.from(c['tags'] ?? []),
    chapters: chapters,
    extra: {
      'isFavorite': c['is_favorite'] == true || c['is_favorite'] == 1,
      'likes': c['likes'],
    },
  );
  ComicResult _result(dynamic data, int page) {
    final content = List<dynamic>.from(data['content'] ?? data['list'] ?? []);
    final total = int.tryParse('${data['total']}') ?? content.length;
    return ComicResult(
      content.map(_comic).toList(),
      next: content.isNotEmpty && page * content.length < total
          ? '${page + 1}'
          : null,
    );
  }

  @override
  Future<ComicResult> explore({String? cursor}) async {
    final page = int.parse(cursor ?? '1');
    return _result(await _api('latest?page=$page'), page);
  }

  @override
  Future<ComicResult> search(
    String query, {
    String? cursor,
    String? sort,
  }) async {
    if (query.isEmpty) return explore(cursor: cursor);
    final page = int.parse(cursor ?? '1');
    return _result(
      await _api(
        'search?search_query=${Uri.encodeQueryComponent(query)}&o=${sort ?? 'mr'}&page=$page',
      ),
      page,
    );
  }

  @override
  Future<List<ComicCategory>> categories() async {
    final data = await _api('categories');
    return (data['categories'] as List? ?? [])
        .map((c) => ComicCategory('${c['slug']}', '${c['name']}'))
        .toList();
  }

  @override
  Future<ComicResult> category(ComicCategory category, {String? cursor}) async {
    final page = int.parse(cursor ?? '1');
    return _result(
      await _api(
        'categories/filter?o=mr&c=${Uri.encodeComponent(category.id)}&page=$page',
      ),
      page,
    );
  }

  @override
  Future<Comic> details(String id) async {
    final data = Map<String, dynamic>.from(await _api('album?id=$id'));
    data['id'] = id;
    final series = List<dynamic>.from(data['series'] ?? []);
    series.sort(
      (a, b) => (int.tryParse('${a['sort']}') ?? 0).compareTo(
        int.tryParse('${b['sort']}') ?? 0,
      ),
    );
    return _comic(
      data,
      chapters: series.isEmpty
          ? [ComicChapter(id, '1')]
          : series
                .map((s) => ComicChapter('${s['id']}', '${s['name']}'))
                .toList(),
    );
  }

  @override
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter) async {
    final data = await _api('chapter?id=${chapter.id}');
    return (data['images'] as List)
        .map(
          (name) => ComicPage(
            '$imageHost/media/photos/${chapter.id}/$name',
            scrambleId: int.tryParse('${data['scramble_id']}') ?? 220980,
            headers: {
              'Referer': 'https://localhost/',
              'X-Requested-With': 'com.example.app',
            },
          ),
        )
        .toList();
  }

  @override
  Future<void> login(String username, String password) async {
    final generation = http.sessionGeneration;
    await _api(
      'login',
      method: 'POST',
      data: {'username': username, 'password': password},
    );
    if (generation != http.sessionGeneration) return;
    await http.saveSession();
    final settings = await _api('setting?app_img_shunt=1');
    if (settings['img_host'] != null) {
      await StorageService.setString(
        'comic_jmcomic_images',
        settings['img_host'],
      );
    }
  }

  @override
  Future<ComicResult> favorites({String? cursor}) async {
    final state = cursor == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(cursor));
    final folders =
        state['folders'] as List? ??
        (await _api('favorite'))['folder_list'] as List;
    final ids = folders.map((f) => f is Map ? '${f['FID']}' : '$f').toList();
    if (ids.isEmpty) ids.add('0');
    final index = state['index'] as int? ?? 0;
    final page = state['page'] as int? ?? 1;
    final data = await _api('favorite?folder_id=${ids[index]}&page=$page&o=mr');
    final items = (data['list'] as List? ?? []).map(_comic).toList();
    final count = (state['count'] as int? ?? 0) + items.length;
    final total = int.tryParse('${data['total']}') ?? count;
    final more = items.isNotEmpty && count < total;
    final next = more
        ? {'folders': ids, 'index': index, 'page': page + 1, 'count': count}
        : index + 1 < ids.length
        ? {'folders': ids, 'index': index + 1, 'page': 1, 'count': 0}
        : null;
    return ComicResult(items, next: next == null ? null : jsonEncode(next));
  }

  @override
  Future<void> setFavorite(Comic comic, bool value) async {
    if ((await details(comic.id)).extra['isFavorite'] != value) {
      await _api('favorite', method: 'POST', data: {'aid': comic.id});
    }
  }

  @override
  Future<List<ComicComment>> comments(Comic comic) async {
    final data = await _api('forum?mode=manhua&aid=${comic.id}&page=1');
    return (data['list'] as List? ?? [])
        .map(
          (c) =>
              ComicComment('${c['username'] ?? ''}', '${c['content'] ?? ''}'),
        )
        .toList();
  }
}

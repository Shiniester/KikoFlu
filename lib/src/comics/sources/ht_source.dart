// Protocol adapted from PicaComic. MIT, Copyright (c) 2023 Nyne.
import 'dart:convert';
import 'package:html/parser.dart' as html;
import '../comic_models.dart';
import '../comic_source.dart';
import '../../services/storage_service.dart';

class HtSource extends ComicSource {
  HtSource(super.http);
  @override
  String get key => 'htmanga';
  @override
  String get name => 'HT Manga';
  @override
  String get website =>
      StorageService.getString('comic_htmanga_endpoint') ??
      'https://www.wnacg.com';
  @override
  bool get hasPasswordLogin => true;
  Map<String, String> get headers => {'Referer': '$website/'};
  String _url(String path) => Uri.parse('$website/').resolve(path).toString();
  static ComicResult parseListing(String body, String base) {
    final doc = html.parse(body);
    final comics = <Comic>[];
    for (final li in doc.querySelectorAll('.gallary_wrap li')) {
      final a = li.querySelector('.pic_box a');
      final id = RegExp(
        r'-aid-(\d+)',
      ).firstMatch(a?.attributes['href'] ?? '')?.group(1);
      if (id == null) continue;
      final title = li.querySelector('.title a');
      final image = li.querySelector('img');
      comics.add(
        Comic(
          source: 'htmanga',
          id: id,
          title: title?.attributes['title'] ?? title?.text ?? id,
          cover: Uri.parse(base)
              .resolve(
                image?.attributes['data-src'] ?? image?.attributes['src'] ?? '',
              )
              .toString(),
          extra: {
            'favoriteId': RegExp(
              r'fav_del-id-(\d+)',
            ).firstMatch(li.outerHtml)?.group(1),
          },
        ),
      );
    }
    final next = doc
        .querySelectorAll('.paginator a')
        .where(
          (a) =>
              a.text.contains('下一') ||
              a.text.contains('Next') ||
              a.text.trim() == '>',
        );
    final href = next.isEmpty ? null : next.first.attributes['href'];
    return ComicResult(
      comics,
      next: href == null ? null : Uri.parse(base).resolve(href).toString(),
    );
  }

  Future<ComicResult> _listing(String url) async =>
      parseListing(await http.text(url, headers: headers), website);
  @override
  Future<ComicResult> explore({String? cursor}) =>
      _listing(cursor ?? '$website/albums.html');
  @override
  Future<ComicResult> search(String query, {String? cursor, String? sort}) =>
      query.isEmpty
      ? explore(cursor: cursor)
      : _listing(
          cursor ??
              '$website/search/?q=${Uri.encodeComponent(query)}&f=_all&s=create_time_DESC&syn=yes',
        );
  @override
  Future<List<ComicCategory>> categories() async {
    final doc = html.parse(await http.text(website, headers: headers));
    final result = <String, ComicCategory>{};
    for (final a in doc.querySelectorAll('a[href]')) {
      final path = a.attributes['href']!;
      if (path.contains('albums-index-cate-')) {
        result[path] = ComicCategory(_url(path), a.text.trim());
      }
    }
    return result.values.toList();
  }

  @override
  Future<ComicResult> category(ComicCategory category, {String? cursor}) =>
      _listing(cursor ?? category.id);
  @override
  Future<Comic> details(String id) async {
    final doc = html.parse(
      await http.text(
        '$website/photos-index-page-1-aid-$id.html',
        headers: headers,
      ),
    );
    return Comic(
      source: key,
      id: id,
      title: doc.querySelector('.userwrap h2')?.text ?? id,
      cover: _url(doc.querySelector('.uwthumb img')?.attributes['src'] ?? ''),
      description: doc.querySelector('.uwconn > p')?.text ?? '',
      tags: doc.querySelectorAll('a.tagshow').map((e) => e.text).toList(),
      chapters: [ComicChapter(id, '1')],
    );
  }

  @override
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter) async {
    final body = await http.text(
      '$website/photos-gallery-aid-${comic.id}.html',
      headers: headers,
    );
    return RegExp(r'(?<=//)[\w./\[\]()?&=%+-]+')
        .allMatches(body)
        .map((m) => 'https:${'//${m[0]}'}')
        .where(
          (u) => RegExp(
            r'\.(jpg|jpeg|png|webp)(\?|$)',
            caseSensitive: false,
          ).hasMatch(u),
        )
        .map((url) => ComicPage(url, headers: headers))
        .toList();
  }

  @override
  Future<void> login(String username, String password) async {
    final generation = http.sessionGeneration;
    final response = await http.request(
      '$website/users-check_login.html',
      method: 'POST',
      headers: {
        ...headers,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      data: {'login_name': username, 'login_pass': password},
    );
    final data = response.data is String
        ? jsonDecode(response.data)
        : response.data;
    if (!RegExp('登录成功|登錄成功').hasMatch('${data['html']}')) {
      throw ComicSourceException('${data['html']}');
    }
    if (generation != http.sessionGeneration) return;
    await http.saveSession();
  }

  static ComicResult parseFavorites(String body, String base) {
    final doc = html.parse(body);
    final comics = <Comic>[];
    for (final row in doc.querySelectorAll('div.asTB')) {
      final link = row.querySelector('p.l_title > a');
      final id = RegExp(
        r'-aid-(\d+)',
      ).firstMatch(link?.attributes['href'] ?? '')?.group(1);
      if (id == null) continue;
      final image = row.querySelector('.thumb img')?.attributes['src'] ?? '';
      comics.add(
        Comic(
          source: 'htmanga',
          id: id,
          title: link!.text.trim(),
          cover: Uri.parse(base).resolve(image).toString(),
          extra: {
            'favoriteId': RegExp(
              r'del-id-(\d+)',
            ).firstMatch(row.outerHtml)?.group(1),
          },
        ),
      );
    }
    final next = doc
        .querySelectorAll('.paginator a')
        .where(
          (a) =>
              a.text.contains('下一') ||
              a.text.contains('Next') ||
              a.text.trim() == '>',
        )
        .firstOrNull;
    return ComicResult(
      comics,
      next: next?.attributes['href'] == null
          ? null
          : Uri.parse(base).resolve(next!.attributes['href']!).toString(),
    );
  }

  @override
  Future<ComicResult> favorites({String? cursor}) async => parseFavorites(
    await http.text(
      cursor ?? '$website/users-users_fav-page-1.html',
      headers: headers,
    ),
    website,
  );
  @override
  Future<void> setFavorite(Comic comic, bool value) async {
    if (value) {
      final doc = html.parse(
        await http.text(
          '$website/users-addfav-id-${comic.id}.html',
          headers: headers,
        ),
      );
      final folder =
          doc
              .querySelectorAll('option')
              .where((e) => (e.attributes['value'] ?? '').isNotEmpty)
              .firstOrNull
              ?.attributes['value'] ??
          '0';
      await http.request(
        '$website/users-save_fav-id-${comic.id}.html',
        method: 'POST',
        headers: {
          ...headers,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        data: {'favc_id': folder},
      );
    } else {
      final record = comic.extra['favoriteId'];
      if (record == null) {
        throw const ComicSourceException(
          'Remove this item from its online favorites list.',
        );
      }
      await http.request(
        '$website/users-fav_del-id-$record.html?ajax=true',
        headers: headers,
      );
    }
  }
}

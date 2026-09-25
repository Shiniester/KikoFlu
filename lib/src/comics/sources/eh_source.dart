// Protocol adapted from PicaComic. MIT, Copyright (c) 2023 Nyne.
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart';
import '../comic_models.dart';
import '../comic_source.dart';
import '../../services/storage_service.dart';

class EhSource extends ComicSource {
  EhSource(super.http);
  @override
  bool get hasComments => true;
  @override
  String get key => 'ehentai';
  @override
  String get name => 'E-Hentai / ExHentai';
  @override
  String get website =>
      StorageService.getString('comic_ehentai_endpoint') ??
      'https://e-hentai.org';
  Map<String, String> get headers => {'Referer': '$website/'};
  Future<Document> _document(String url) async =>
      html.parse(await http.text(url, headers: headers));
  static ComicResult parseListing(String body, String base) {
    final doc = html.parse(body);
    final comics = <String, Comic>{};
    for (final a in doc.querySelectorAll('a[href]')) {
      final match = RegExp(
        r'/g/(\d+)/([\w]+)/?',
      ).firstMatch(a.attributes['href']!);
      if (match == null) continue;
      final id = '${match[1]}/${match[2]}';
      var card = a.parent!;
      for (Element? parent = a.parent; parent != null; parent = parent.parent) {
        if (parent.localName == 'tr' ||
            parent.classes.contains('gl1t') ||
            parent.classes.contains('gl1e')) {
          card = parent;
          break;
        }
      }
      final title = card.querySelector('.glink')?.text.trim() ?? a.text.trim();
      if (title.isEmpty) continue;
      final image = card.querySelector('img');
      var cover =
          image?.attributes['data-src'] ?? image?.attributes['src'] ?? '';
      if (cover.isNotEmpty) cover = Uri.parse(base).resolve(cover).toString();
      comics[id] = Comic(
        source: 'ehentai',
        id: id,
        title: title,
        cover: cover,
        tags: card
            .querySelectorAll('.gt,.gtl')
            .map((t) => t.attributes['title'] ?? t.text)
            .toList(),
      );
    }
    final next = doc.querySelector('#dnext')?.attributes['href'];
    return ComicResult(
      comics.values.toList(),
      next: next == null ? null : Uri.parse(base).resolve(next).toString(),
    );
  }

  Future<ComicResult> _listing(String url) async =>
      parseListing(await http.text(url, headers: headers), website);
  @override
  Future<ComicResult> search(String query, {String? cursor, String? sort}) =>
      _listing(cursor ?? '$website/?f_search=${Uri.encodeComponent(query)}');
  @override
  Future<List<ComicCategory>> categories() async => const [
    ComicCategory('language:chinese', 'Chinese'),
    ComicCategory('language:japanese', 'Japanese'),
    ComicCategory('language:english', 'English'),
  ];
  @override
  Future<Comic> details(String id) async {
    final doc = await _document('$website/g/$id/');
    final style = doc.querySelector('#gd1 > div')?.attributes['style'] ?? '';
    final cover =
        RegExp(r'url\(([^)]+)\)')
            .firstMatch(style)
            ?.group(1)
            ?.replaceAll('"', '')
            .replaceAll("'", '') ??
        '';
    final title = doc.querySelector('#gj')?.text.trim();
    return Comic(
      source: key,
      id: id,
      title: title?.isNotEmpty == true
          ? title!
          : doc.querySelector('#gn')?.text ?? id,
      cover: cover,
      description: doc.querySelector('#gdd')?.text.trim() ?? '',
      tags: doc
          .querySelectorAll('#taglist .gt,#taglist .gtl')
          .map((e) => e.attributes['id']?.replaceFirst('td_', '') ?? e.text)
          .toList(),
      chapters: [ComicChapter(id, '1')],
      rating: doc.querySelector('#rating_label')?.text,
      extra: {
        'isFavorite':
            doc.querySelector('#favoritelink')?.text != 'Add to Favorites',
      },
    );
  }

  @override
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter) async {
    final result = <String, ComicPage>{};
    var page = 0;
    var last = 0;
    do {
      final doc = await _document('$website/g/${comic.id}/?p=$page');
      for (final a in doc.querySelectorAll('#gdt a[href]')) {
        final url = Uri.parse(
          website,
        ).resolve(a.attributes['href']!).toString();
        result[url] = ComicPage(url, headers: headers, resolveHtml: true);
      }
      for (final a in doc.querySelectorAll('.ptt a[href]')) {
        final n =
            int.tryParse(
              Uri.parse(a.attributes['href']!).queryParameters['p'] ?? '',
            ) ??
            0;
        if (n > last) last = n;
      }
      page++;
    } while (page <= last);
    return result.values.toList();
  }

  @override
  Future<ComicResult> favorites({String? cursor}) =>
      _listing(cursor ?? '$website/favorites.php');
  @override
  Future<void> setFavorite(Comic comic, bool value) async {
    final parts = comic.id.split('/');
    await http.request(
      'https://e-hentai.org/gallerypopups.php?gid=${parts[0]}&t=${parts[1]}&act=addfav',
      method: 'POST',
      headers: {
        ...headers,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      data: {
        'favcat': value ? '0' : 'favdel',
        'favnote': '',
        'apply': value ? 'Add to Favorites' : 'Apply Changes',
        'update': '1',
      },
    );
  }

  @override
  Future<List<ComicComment>> comments(Comic comic) async {
    final doc = await _document('$website/g/${comic.id}/?hc=1');
    return doc
        .querySelectorAll('.c1')
        .map(
          (c) => ComicComment(
            c.querySelector('.c3')?.text ?? '',
            c.querySelector('.c6')?.text ?? '',
            score: c.querySelector('.c5 > span')?.text,
          ),
        )
        .toList();
  }
}

// Protocol adapted from PicaComic. MIT, Copyright (c) 2023 Nyne.
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;
import '../../services/storage_service.dart';
import '../comic_models.dart';
import '../comic_source.dart';
import 'hitomi_search.dart';

class HitomiSource extends ComicSource {
  HitomiSource(super.http);
  @override
  String get key => 'hitomi';
  @override
  String get name => 'Hitomi';
  @override
  String get website => 'https://hitomi.la';
  @override
  bool get hasAccount => false;
  @override
  bool get hasRemoteFavorites => false;
  String get domain =>
      StorageService.getString('comic_hitomi_domain') ??
      'gold-usergeneratedcontent.net';
  Map<String, String> get headers => {'Referer': '$website/'};
  String? _lastQuery;
  Future<List<int>>? _searchIds;
  static List<int> decodeIds(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    return [
      for (var i = 0; i + 4 <= bytes.length; i += 4)
        data.getUint32(i, Endian.big),
    ];
  }

  Future<Comic> _brief(int id) async {
    final doc = html.parse(
      await http.text(
        'https://ltn.$domain/galleryblock/$id.html',
        headers: headers,
      ),
    );
    var cover =
        doc
            .querySelector('picture source')
            ?.attributes['data-srcset']
            ?.split(' ')
            .first ??
        '';
    if (cover.startsWith('//')) cover = 'https:$cover';
    if (cover.isNotEmpty) {
      cover = Uri.parse(cover)
          .replace(host: 'atn.$domain')
          .toString()
          .replaceAll('avifbigtn', 'webpbigtn')
          .replaceAll('.avif', '.webp');
    }
    return Comic(
      source: key,
      id: '$id',
      title: doc.querySelector('h1.lillie a')?.text ?? '$id',
      cover: cover,
      tags: doc.querySelectorAll('.relatedtags a').map((e) => e.text).toList(),
      extra: {'sourceDate': doc.querySelector('.dj-content > p')?.text.trim()},
    );
  }

  @override
  Future<ComicResult> explore({String? cursor}) async {
    final offset = int.parse(cursor ?? '0');
    final response = await http.request(
      'https://ltn.$domain/index-all.nozomi',
      headers: {...headers, 'Range': 'bytes=$offset-${offset + 99}'},
      type: ResponseType.bytes,
    );
    final bytes = Uint8List.fromList(List<int>.from(response.data));
    final ids = decodeIds(bytes);
    final total =
        int.tryParse(
          response.headers.value('content-range')?.split('/').last ?? '',
        ) ??
        offset + bytes.length;
    return ComicResult(
      await Future.wait(ids.map(_brief)),
      next: offset + bytes.length < total ? '${offset + bytes.length}' : null,
    );
  }

  @override
  Future<ComicResult> search(
    String query, {
    String? cursor,
    String? sort,
  }) async {
    if (query.trim().isEmpty) return explore(cursor: cursor);
    if (query != _lastQuery) {
      _lastQuery = query;
      _searchIds = HitomiSearch(query, domain, http.dio).search();
    }
    final request = _searchIds!;
    late List<int> ids;
    try {
      ids = await request;
    } catch (_) {
      if (identical(request, _searchIds)) _lastQuery = null;
      rethrow;
    }
    final start = int.parse(cursor ?? '0');
    final end = (start + 25).clamp(0, ids.length);
    return ComicResult(
      await Future.wait(ids.sublist(start, end).map(_brief)),
      next: end < ids.length ? '$end' : null,
    );
  }

  @override
  Future<List<ComicCategory>> categories() async => const [
    ComicCategory('language:chinese', 'Chinese'),
    ComicCategory('language:japanese', 'Japanese'),
    ComicCategory('language:english', 'English'),
  ];
  @override
  Future<Comic> details(String id) async {
    final brief = await _brief(int.parse(id));
    final body = await http.text(
      'https://ltn.$domain/galleries/$id.js',
      headers: headers,
    );
    final json = jsonDecode(
      body.substring(body.indexOf('{'), body.lastIndexOf('}') + 1),
    );
    return Comic(
      source: key,
      id: id,
      title: json['japanese_title'] ?? json['title'] ?? brief.title,
      cover: brief.cover,
      tags: (json['tags'] as List? ?? []).map((t) => '${t['tag']}').toList(),
      chapters: [ComicChapter(id, '1')],
      extra: {
        'files': json['files'],
        if (json['date'] != null) 'sourceDate': json['date'],
      },
    );
  }

  static String imagePath(Map<String, dynamic> file, String gg, String domain) {
    final hash = file['hash'] as String;
    final tail = hash.substring(hash.length - 3);
    final number = int.parse('${tail[2]}${tail.substring(0, 2)}', radix: 16);
    final cases = RegExp(
      r'case (\d+)',
    ).allMatches(gg).map((m) => int.parse(m[1]!)).toSet();
    final initial = int.parse(RegExp(r'var o = (\d+)').firstMatch(gg)![1]!);
    final bucket = cases.contains(number) ? (~initial & 1) : initial;
    final base = RegExp(
      "b: '([^']+)'",
    ).firstMatch(gg)![1]!.replaceFirst(RegExp(r'/$'), '');
    // The w1/w2 channel serves WebP even when gallery metadata only lists AVIF.
    return 'https://w${bucket + 1}.$domain/$base/$number/$hash.webp';
  }

  @override
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter) async {
    final files =
        comic.extra['files'] ?? (await details(comic.id)).extra['files'];
    final gg = await http.text('https://ltn.$domain/gg.js', headers: headers);
    return (files as List)
        .map(
          (f) => ComicPage(
            imagePath(Map<String, dynamic>.from(f), gg, domain),
            headers: {'Referer': '$website/reader/${comic.id}.html'},
          ),
        )
        .toList();
  }
}

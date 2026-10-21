import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/services/japanese_asmr_service.dart';

class _Pages implements HttpClientAdapter {
  _Pages(this.pages);

  final Map<String, String> pages;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final body = pages[options.uri.path];
    if (body == null) throw StateError('Unexpected request: ${options.uri}');
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        'content-type': ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _card(int id, String classes) =>
    '''
<li class="site-archive-post $classes">
<h2 class="entry-title"><a href="/$id/">Work $id</a></h2></li>''';

String _archive(String identity, String cards, {int? next, int last = 1}) =>
    '''
<body class="archive $identity"><main class="site-main">$cards
${next == null ? '' : '<a class="next page-numbers" href="page/$next/">Next</a>'}
<a class="page-numbers">$last</a></main></body>''';

SearchCondition _condition(String path, {bool exclude = false}) =>
    SearchCondition(
      id: path,
      type: path.startsWith('/category/') ? SearchType.circle : SearchType.tag,
      value: 'Display name differs from slug',
      sourcePath: path,
      isExclude: exclude,
    );

JapaneseAsmrService _service(_Pages pages) =>
    JapaneseAsmrService(dio: Dio()..httpClientAdapter = pages);

void main() {
  test(
    'reads directory identities, counts, names and removes duplicate paths',
    () async {
      final pages = _Pages({
        '/tags/': '''
<div class="entry-content"><div class="tag-groups-tag">
<a href="/tag/%E8%80%B3/" title="(1,234)"><span class="tag-groups-label">Ear &amp; voice</span></a>
<a href="https://japaneseasmr.com/tag/%e8%80%b3/" title="(1,234)"><span class="tag-groups-label">Ear &amp; voice</span></a>
<a href="/tag/other/" title="(2)"><span class="tag-groups-label">Other</span></a>
<a href="https://external.example/tag/outside/" title="(9)"><span class="tag-groups-label">External</span></a>
<a href="/category/studio/" title="(9)"><span class="tag-groups-label">Wrong type</span></a>
</div></div>''',
      });
      final entries = await _service(pages).getSearchCatalog(SearchType.tag);
      expect(entries, [
        {'name': 'Ear & voice', 'sourcePath': '/tag/%E8%80%B3/', 'count': 1234},
        {'name': 'Other', 'sourcePath': '/tag/other/', 'count': 2},
      ]);
    },
  );

  test('uses separate CV and circle directories', () async {
    final pages = _Pages({
      '/cv/':
          '<div class="entry-content"><span class="tag-groups-tag"><a href="/tag/voice/" title="(3)"><span class="tag-groups-label">Voice</span></a></span></div>',
      '/circles/':
          '<div class="entry-content"><span class="tag-groups-tag"><a href="/category/studio/" title="(5)"><span class="tag-groups-label">Studio</span></a></span></div>',
    });
    final service = _service(pages);
    expect(
      (await service.getSearchCatalog(SearchType.va)).single['sourcePath'],
      '/tag/voice/',
    );
    expect(
      (await service.getSearchCatalog(SearchType.circle)).single['sourcePath'],
      '/category/studio/',
    );
  });

  test(
    'keeps the literal intersection separator and encodes each tag slug',
    () async {
      final pages = _Pages({
        '/tag/%E8%80%B3+voice/': _archive(
          'tag-42',
          _card(1, 'tag-42 tag-voice'),
        ),
      });
      final result = await _service(pages).searchWorks(
        keyword: '',
        page: 1,
        pageSize: 14,
        conditions: [_condition('/tag/%e8%80%b3/'), _condition('/tag/voice/')],
      );
      expect((result['works'] as List).single['id'], -1);
      expect(result['pagination']['totalCount'], 1);
      expect(pages.requests.single.path, '/tag/%E8%80%B3+voice/');
    },
  );

  test('uses native numeric taxonomy identity for Japanese slugs', () async {
    final pages = _Pages({
      '/tag/%E8%80%B3/': _archive(
        'tag-42',
        '${_card(1, 'tag-42 category-studio')}${_card(2, 'tag-42')}',
      ),
      '/category/studio/': _archive('category-studio category-19', ''),
    });
    final result = await _service(pages).searchWorks(
      keyword: '',
      page: 1,
      pageSize: 10,
      conditions: [
        _condition('/tag/%E8%80%B3/'),
        _condition('/category/studio/', exclude: true),
      ],
    );
    expect((result['works'] as List).map((work) => work['id']), [-2]);
    expect(result['pagination']['totalCount'], 1);
    expect(result['pagination']['hasMore'], false);
    expect(pages.requests.length, 2);
  });

  test(
    'fills filtered pages across native pages and only scans through lookahead',
    () async {
      final pages = _Pages({
        '/tag/voice/': _archive(
          'tag-voice tag-1',
          '${_card(1, 'tag-voice category-studio')}${_card(2, 'tag-voice')}',
          next: 2,
          last: 3,
        ),
        '/tag/voice/page/2/': _archive(
          'tag-voice tag-1',
          '${_card(3, 'tag-voice')}${_card(4, 'tag-voice')}',
          next: 3,
          last: 3,
        ),
        '/tag/voice/page/3/': _archive(
          'tag-voice tag-1',
          _card(5, 'tag-voice'),
        ),
        '/category/studio/': _archive('category-studio category-19', ''),
      });
      final service = _service(pages);
      final filters = [
        _condition('/tag/voice/'),
        _condition('/category/studio/', exclude: true),
      ];
      final first = await service.searchWorks(
        keyword: '',
        page: 1,
        pageSize: 2,
        conditions: filters,
      );
      expect((first['works'] as List).map((work) => work['id']), [-2, -3]);
      expect(first['pagination']['totalCount'], isNull);
      expect(first['pagination']['hasMore'], true);
      expect(
        pages.requests.map((uri) => uri.path),
        isNot(contains('/tag/voice/page/3/')),
      );
      final second = await service.searchWorks(
        keyword: '',
        page: 2,
        pageSize: 2,
        conditions: filters,
      );
      expect((second['works'] as List).map((work) => work['id']), [-4, -5]);
      expect(second['pagination']['totalCount'], 4);
      expect(second['pagination']['hasMore'], false);
    },
  );

  test(
    'combines native keyword search with exact positive and negative classifications',
    () async {
      final pages = _Pages({
        '/tag/voice/': _archive('tag-voice tag-1', _card(99, 'tag-voice')),
        '/category/studio/': _archive('category-studio category-19', ''),
        '/search/RJ01234567/': _archive(
          '',
          '${_card(1, 'tag-other')}${_card(2, 'tag-voice category-studio')}${_card(3, 'tag-voice')}',
        ),
      });
      final result = await _service(pages).searchWorks(
        keyword: 'RJ01234567',
        page: 1,
        pageSize: 10,
        conditions: [
          _condition('/tag/voice/'),
          _condition('/category/studio/', exclude: true),
        ],
      );
      expect((result['works'] as List).map((work) => work['id']), [-3]);
    },
  );

  test(
    'rejects a directory challenge instead of caching an empty list',
    () async {
      final pages = _Pages({
        '/cv/': '<script>window._cf_chl_opt = {};</script>',
      });
      expect(
        _service(pages).getSearchCatalog(SearchType.va),
        throwsA(isA<JapaneseAsmrVerificationRequiredException>()),
      );
    },
  );

  test(
    'rejects external classification paths before making requests',
    () async {
      final pages = _Pages({});
      expect(
        _service(pages).searchWorks(
          keyword: '',
          page: 1,
          pageSize: 10,
          conditions: [_condition('https://external.example/tag/voice/')],
        ),
        throwsArgumentError,
      );
      expect(pages.requests, isEmpty);
    },
  );
}

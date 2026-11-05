import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/videos/jable_client.dart';
import 'package:kikoeru_flutter/src/videos/missav_browser_adapter.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

void main() {
  test(
    'parses category cards and menu tags without pagination links',
    () async {
      final adapter = _Adapter(
        (_) => _html('''
        <html><head><title>Categories</title></head><body>
          <div class="app-nav">
            <div class="title-box">Sections</div><div class="row">
              <a href="/categories/">Topics</a>
            </div>
            <div class="title-box">Clothing</div><div class="row">
              <a class="tag" href="/tags/glasses/">Glasses</a>
              <a class="tag" href="https://ads.example/tag/">Ad tag</a>
            </div>
          </div>
          <div id="list_categories_video_categories_list">
            <div class="video-img-box">
              <a href="/categories/drama/"><img src="/covers/drama.jpg">
                <div class="absolute-center"><h4>Drama</h4></div>
              </a>
            </div>
            <div class="video-img-box">
              <a href="https://ads.example/category/">
                <h4>Advertisement</h4>
              </a>
            </div>
            <div class="img-box"><a href="/categories/legacy/">
              <div class="absolute-center"><h4>Legacy category</h4></div>
            </a></div>
          </div>
          <nav class="pagination"><a href="/categories/2/">2</a></nav>
        </body></html>
      '''),
      );
      final client = _client(adapter);

      final page = await client.searchFilterOptions(
        VideoSearchFilterKind.genre,
      );

      expect(page.links.map((link) => (link.label, link.url, link.kind)), [
        ('Drama', 'https://jable.tv/categories/drama/', VideoLinkKind.category),
        (
          'Legacy category',
          'https://jable.tv/categories/legacy/',
          VideoLinkKind.category,
        ),
        ('Glasses', 'https://jable.tv/tags/glasses/', VideoLinkKind.tag),
      ]);
      expect(page.links.first.cover, 'https://jable.tv/covers/drama.jpg');
      client.dispose();
    },
  );

  test(
    'uses the adjacent numeric page and ignores the last-page arrow',
    () async {
      final adapter = _Adapter((request) {
        if (request.uri.path == '/latest-updates/') {
          return _html('''
          <html><body><nav class="pagination">
            <a class="active" href="/latest-updates/">1</a>
            <a href="/latest-updates/2/">2</a>
            <a href="/latest-updates/3/">3</a>
            <a href="/latest-updates/1660/">»</a>
          </nav></body></html>
        ''');
        }
        if (request.uri.path == '/latest-updates/2/') {
          return _html('''
          <html><body><nav class="pagination">
            <a href="/latest-updates/">1</a>
            <a class="active" href="/latest-updates/2/">2</a>
            <a href="/latest-updates/3/">3</a>
            <a href="/latest-updates/1660/">»</a>
          </nav></body></html>
        ''');
        }
        return _html('''
        <html><body><nav class="pagination">
          <a href="/latest-updates/">1</a>
          <a href="/latest-updates/2/">2</a>
          <a class="active" href="/latest-updates/1660/">1660</a>
          <a href="/latest-updates/1660/">»</a>
        </nav></body></html>
      ''');
      });
      final client = _client(adapter);

      final first = await client.browse('https://jable.tv/latest-updates/');
      final second = await client.browse(first.nextUrl!);
      final last = await client.browse('https://jable.tv/latest-updates/1660/');

      expect(first.nextUrl, 'https://jable.tv/latest-updates/2/');
      expect(second.previousUrl, 'https://jable.tv/latest-updates/');
      expect(second.nextUrl, 'https://jable.tv/latest-updates/3/');
      expect(last.currentPage, 1660);
      expect(last.nextUrl, isNull);
      expect(first.jumpMaxPage, 1660);
      expect(first.pageUrl(7), 'https://jable.tv/latest-updates/7/');
      client.dispose();
    },
  );

  test(
    'keeps sort and unrelated query values in path pagination jumps',
    () async {
      final adapter = _Adapter(
        (_) => _html('''
        <html><body><nav class="pagination">
          <a class="page-link active" href="/hot/?sort_by=video_viewed_today&amp;view=grid">01</a>
          <a class="page-link" href="/hot/2/?sort_by=video_viewed_today&amp;view=grid">02</a>
          <a href="/hot/1660/?sort_by=video_viewed_today&amp;view=grid">最後 »</a>
        </nav></body></html>
      '''),
      );
      final client = _client(adapter);

      final page = await client.browse(
        'https://jable.tv/hot/?sort_by=video_viewed_today&view=grid',
      );

      expect(page.currentPage, 1);
      expect(page.nextUrl, contains('/hot/2/?sort_by=video_viewed_today'));
      final jump = Uri.parse(page.pageUrl(5));
      expect(jump.path, '/hot/5/');
      expect(jump.queryParameters, {
        'sort_by': 'video_viewed_today',
        'view': 'grid',
      });
      expect(page.jumpMaxPage, 1660);
      client.dispose();
    },
  );

  test('uses Jable from pagination while preserving other filters', () async {
    final adapter = _Adapter(
      (_) => _html('''
        <html><body><nav class="pagination">
          <a class="page-link active" href="/search/needle/?from=1&amp;lang=zh">01</a>
          <a class="page-link" href="/search/needle/?from=2&amp;lang=zh">02</a>
          <a href="/search/needle/?from=120&amp;lang=zh">最後 »</a>
        </nav></body></html>
      '''),
    );
    final client = _client(adapter);

    final page = await client.browse(
      'https://jable.tv/search/needle/?from=1&lang=zh',
    );

    expect(page.currentPage, 1);
    expect(Uri.parse(page.nextUrl!).queryParameters, {
      'from': '2',
      'lang': 'zh',
    });
    final jump = Uri.parse(page.pageUrl(3));
    expect(jump.path, '/search/needle/');
    expect(jump.queryParameters, {'from': '3', 'lang': 'zh'});
    expect(page.jumpMaxPage, 120);
    client.dispose();
  });

  test(
    'parses source-provided sort options from KVS parameters and hrefs',
    () async {
      final adapter = _Adapter(
        (_) => _html('''
        <html><body>
          <div class="filters">
            <a class="filter-item" href="#" data-parameters="&amp;sort_by=video_viewed_today">Today</a>
            <a class="filter-item" href="#" data-parameters="sort_by:video_viewed_week">This week</a>
            <a class="filter-item" href="#" data-parameters="{&quot;sort_by&quot;:&quot;video_viewed_month&quot;}">This month</a>
            <a class="filter-item" href="#" data-parameters="sort_by=video_viewed">All time</a>
            <a href="?sort_by=source_rank&amp;view=grid">Source rank</a>
            <a href="https://ads.example/?sort_by=bad">Advertisement</a>
            <a href="/search/other/">Other catalog</a>
          </div>
        </body></html>
      '''),
      );
      final client = _client(adapter);

      final page = await client.browse('https://jable.tv/hot/?view=grid');

      expect(page.navigation.map((link) => link.label), [
        'Today',
        'This week',
        'This month',
        'All time',
        'Source rank',
      ]);
      expect(
        page.navigation.map(
          (link) => Uri.parse(link.url).queryParameters['sort_by'],
        ),
        [
          'video_viewed_today',
          'video_viewed_week',
          'video_viewed_month',
          'video_viewed',
          'source_rank',
        ],
      );
      expect(
        page.navigation.every((link) => link.kind == VideoLinkKind.navigation),
        isTrue,
      );
      client.dispose();
    },
  );

  test(
    'carries the selected sort into adjacent and jump pagination URLs',
    () async {
      final adapter = _Adapter(
        (_) => _html('''
        <html><body>
          <div class="filters">
            <a class="filter-item" data-parameters="sort_by=video_viewed_week">This week</a>
          </div>
          <nav class="pagination">
            <a href="/hot/?view=grid">01</a>
            <a class="page-link active" data-parameters="sort_by=video_viewed_week" href="/hot/2/?view=grid">02</a>
            <a href="/hot/3/?view=grid">03</a>
            <a href="/hot/1660/?view=grid">最後 »</a>
          </nav>
        </body></html>
      '''),
      );
      final client = _client(adapter);

      final page = await client.browse(
        'https://jable.tv/hot/2/?sort_by=video_viewed_week&view=grid',
      );

      expect(page.currentPage, 2);
      expect(Uri.parse(page.previousUrl!).path, '/hot/');
      expect(Uri.parse(page.previousUrl!).queryParameters, {
        'sort_by': 'video_viewed_week',
        'view': 'grid',
      });
      expect(Uri.parse(page.nextUrl!).path, '/hot/3/');
      expect(Uri.parse(page.nextUrl!).queryParameters, {
        'sort_by': 'video_viewed_week',
        'view': 'grid',
      });
      final jump = Uri.parse(page.pageUrl(5));
      expect(jump.path, '/hot/5/');
      expect(jump.queryParameters, {
        'sort_by': 'video_viewed_week',
        'view': 'grid',
      });
      expect(page.navigation.map((link) => link.label), ['This week']);
      client.dispose();
    },
  );

  test(
    'distinguishes model directory page 2 from a numeric model profile',
    () async {
      final adapter = _Adapter((request) {
        if (request.uri.path == '/models/2/') {
          return _html('''
          <html><body>
            <div id="site-content">
              <div class="video-img-box"><a href="/models/model-hash/">
                <img src="/models/model.jpg"><h4>Model name</h4>
              </a></div>
            </div>
            <nav class="pagination">
              <a href="/models/">01</a>
              <a class="page-link active" href="/models/2/">02</a>
              <a href="/models/3/">03</a>
            </nav>
          </body></html>
        ''');
        }
        return _html('''
        <html><body>
          <div class="video-info"><h1>Numeric model profile</h1></div>
          <div id="list_videos_model_videos_list">
            <div class="video-img-box"><a href="/videos/model-video/"><img src="/video.jpg">
              <div class="detail"><h6 class="title">Model video</h6></div>
            </a></div>
          </div>
          <nav class="pagination">
            <a class="page-link active" href="/models/123/">01</a>
            <a href="/models/123/2/">02</a>
          </nav>
        </body></html>
      ''');
      });
      final client = _client(adapter);

      final directory = await client.searchFilterOptions(
        VideoSearchFilterKind.actor,
        pageUrl: 'https://jable.tv/models/2/',
      );
      final profile = await client.browse(
        'https://jable.tv/models/123/?from=1',
      );

      expect(directory.currentPage, 2);
      expect(directory.links.single.label, 'Model name');
      expect(directory.links.single.url, 'https://jable.tv/models/model-hash/');
      expect(directory.links.single.cover, 'https://jable.tv/models/model.jpg');
      expect(directory.pageUrl(3), 'https://jable.tv/models/3/');
      expect(profile.currentPage, 1);
      expect(profile.links, isEmpty);
      expect(profile.nextUrl, 'https://jable.tv/models/123/2/');
      client.dispose();
    },
  );

  test('intersects the encoded search and selected filter catalogs', () async {
    const searchResults = '''
      <div id="list_videos_search_videos_list">
        <div class="video-img-box"><a href="/videos/match/"><img src="/match.jpg">
          <div class="detail"><h6 class="title">Match</h6></div>
        </a></div>
        <div class="video-img-box"><a href="/videos/search-only/"><img src="/search.jpg">
          <div class="detail"><h6 class="title">Search only</h6></div>
        </a></div>
      </div>
    ''';
    const filterResults = '''
      <div id="list_videos_tag_videos_list">
        <div class="video-img-box"><a href="/videos/match/"><img src="/match.jpg">
          <div class="detail"><h6 class="title">Match</h6></div>
        </a></div>
        <div class="video-img-box"><a href="/videos/filter-only/"><img src="/filter.jpg">
          <div class="detail"><h6 class="title">Filter only</h6></div>
        </a></div>
      </div>
    ''';
    final adapter = _Adapter((request) {
      if (request.uri.path.startsWith('/search/')) return _html(searchResults);
      return _html(filterResults);
    });
    final client = _client(adapter);

    final results = await client.searchWithFilters('needle words', const [
      VideoLink(
        label: 'Drama',
        url: 'https://jable.tv/tags/drama/?from=3&sort_by=post_date',
        kind: VideoLinkKind.tag,
      ),
    ]);

    expect(results.map((video) => video.id), ['match']);
    final catalogs = adapter.requests
        .where((request) => !request.uri.path.startsWith('/videos/'))
        .toList();
    expect(catalogs.map((request) => request.uri.path), [
      '/search/needle%20words/',
      '/tags/drama/',
    ]);
    expect(catalogs.last.uri.queryParameters, {'sort_by': 'post_date'});
    expect(
      adapter.requests.where(
        (request) => request.uri.path.startsWith('/videos/'),
      ),
      hasLength(4),
    );
    client.dispose();
  });

  test(
    'rejects foreign filter URLs and stops a stale filter request',
    () async {
      final adapter = _Adapter((_) => _html('<html><body></body></html>'));
      final client = _client(adapter);

      await expectLater(
        client.searchWithFilters('', const [
          VideoLink(label: 'Bad', url: 'https://ads.example/tags/bad/'),
        ]),
        throwsA(isA<VideoSourceException>()),
      );
      final stale = await client.searchWithFilters('', const [
        VideoLink(label: 'Drama', url: 'https://jable.tv/tags/drama/'),
      ], isCurrent: () => false);

      expect(stale, isEmpty);
      expect(adapter.requests, isEmpty);
      client.dispose();
    },
  );

  test('encodes a search query in the native route', () async {
    final adapter = _Adapter((_) => _html('<html><body>Results</body></html>'));
    final client = _client(adapter);

    await client.search('sample title');

    expect(
      adapter.requests.single.uri.toString(),
      contains('/search/sample%20title/'),
    );
    client.dispose();
  });

  test(
    'parses catalog card covers and durations inside the video list',
    () async {
      final adapter = _Adapter(
        (_) => _html('''
        <html><body>
          <div id="list_videos_hot_videos_list">
            <div class="row">
              <div class="video-img-box">
                <div class="img-box"><a href="/videos/card-one/">
                  <img data-src="/covers/card-one.jpg">
                  <span class="absolute-bottom-right">2:04:19</span>
                </a></div>
                <div class="detail"><h6 class="title">Card one</h6></div>
              </div>
            </div>
          </div>
          <aside><div class="video-img-box">
            <a href="/videos/sidebar/" class="title">Sidebar card</a>
          </div></aside>
        </body></html>
      '''),
      );
      final client = _client(adapter);

      final page = await client.browse('https://jable.tv/hot/');

      expect(page.videos, hasLength(1));
      expect(page.videos.single.id, 'card-one');
      expect(page.videos.single.title, 'Card one');
      expect(page.videos.single.cover, 'https://jable.tv/covers/card-one.jpg');
      expect(page.videos.single.durationSeconds, 7459);
      client.dispose();
    },
  );

  test('returns catalog cards after optional metadata is complete', () async {
    final adapter = _Adapter((request) {
      if (request.uri.path == '/hot/') {
        return _html('''
          <html><body><div id="list_videos_hot_videos_list">
            <div class="video-img-box"><a href="/videos/marked/"></a>
              <div class="detail"><h6 class="title">Marked card</h6></div>
            </div>
            <div class="video-img-box"><a href="/videos/unavailable/"></a>
              <div class="detail"><h6 class="title">Unavailable card</h6></div>
            </div>
            <div class="video-img-box"><a href="/videos/clean/"></a>
              <div class="detail"><h6 class="title">中文剧情泄露</h6></div>
            </div>
          </div></body></html>
        ''');
      }
      if (request.uri.path == '/videos/unavailable/') {
        return _html('<html><body>Unavailable</body></html>', statusCode: 500);
      }
      if (request.uri.path == '/videos/clean/') {
        return _html('''
          <html><body>
            <div class="video-info"><div class="info-header">
              <span class="inactive-color">2025-02-03</span>
            </div></div>
            <form><input type="password" name="account-password"></form>
            <aside>无码推荐广告</aside>
          </body></html>
        ''');
      }
      return _html('''
        <html><head>
          <meta property="og:title" content="Marked title">
          <meta property="og:image" content="/covers/marked.jpg">
        </head><body>
          <div class="video-info">
            <div class="info-header">
              <span class="inactive-color">上市於 2025-01-02</span>
              <div class="models"><a class="model" href="/models/sample-model/">
                <span class="rounded-circle" data-original-title="Sample model"></span>
              </a></div>
            </div>
            <div class="tags">
              <a class="cat" href="/categories/chinese-subtitle/">Chinese subtitle</a>
              <a class="cat" href="/categories/uncensored/">Uncensored</a>
              <a href="/tags/drama/">Drama</a>
            </div>
          </div>
        </body></html>
      ''');
    });
    final client = _client(adapter);
    VideoCatalogPage? staged;

    final page = await client.browse(
      'https://jable.tv/hot/',
      onParsed: (value) => staged = value,
    );

    expect(staged!.videos.first.actors, isEmpty);
    expect(page.videos.first.title, 'Marked title');
    expect(page.videos.first.cover, 'https://jable.tv/covers/marked.jpg');
    expect(page.videos.first.releaseDate, '2025-01-02');
    expect(page.videos.first.actors.single.label, 'Sample model');
    expect(page.videos.first.tags.map((tag) => tag.label), [
      'Chinese subtitle',
      'Uncensored',
      'Drama',
    ]);
    expect(page.videos.first.hasSubtitles, isTrue);
    expect(page.videos.first.isUncensored, isTrue);
    expect(page.videos[1].title, 'Unavailable card');
    expect(page.videos[1].actors, isEmpty);
    expect(page.videos[2].title, '中文剧情泄露');
    expect(page.videos[2].hasSubtitles, isFalse);
    expect(page.videos[2].isUncensored, isFalse);
    expect(adapter.requests.map((request) => request.uri.path), [
      '/hot/',
      '/videos/marked/',
      '/videos/unavailable/',
      '/videos/clean/',
    ]);
    client.dispose();
  });

  test(
    'stops catalog enrichment when a video requires browser verification',
    () async {
      final adapter = _Adapter((request) {
        if (request.uri.path == '/hot/') {
          return _html('''
          <div id="list_videos_hot_videos_list">
            <div class="video-img-box"><a href="/videos/blocked/"></a>
              <div class="detail"><h6>Blocked</h6></div>
            </div>
            <div class="video-img-box"><a href="/videos/later/"></a>
              <div class="detail"><h6>Later</h6></div>
            </div>
          </div>
        ''');
        }
        return _html('<html><body>Denied</body></html>', statusCode: 403);
      });
      final client = _client(adapter);

      await expectLater(
        client.browse('https://jable.tv/hot/'),
        throwsA(isA<JableVerificationRequiredException>()),
      );

      expect(adapter.requests.map((request) => request.uri.path), [
        '/hot/',
        '/videos/blocked/',
      ]);
      client.dispose();
    },
  );

  test(
    'stops catalog enrichment on a login page without video metadata',
    () async {
      final adapter = _Adapter((request) {
        if (request.uri.path == '/hot/') {
          return _html('''
          <div id="list_videos_hot_videos_list">
            <div class="video-img-box"><a href="/videos/guest/"></a>
              <div class="detail"><h6>Guest video</h6></div>
            </div>
          </div>
        ''');
        }
        return _html('''
        <html><body><form action="/login/">
          <input type="password" name="password">
        </form></body></html>
      ''');
      });
      final client = _client(adapter);

      await expectLater(
        client.browse('https://jable.tv/hot/'),
        throwsA(isA<JableLoginRequiredException>()),
      );
      expect(adapter.requests, hasLength(2));
      client.dispose();
    },
  );

  test('stops remaining metadata requests when the session changes', () async {
    final detailStarted = Completer<void>();
    final finishDetail = Completer<ResponseBody>();
    final adapter = _Adapter((request) async {
      if (request.uri.path == '/hot/') {
        return _html('''
          <div id="list_videos_hot_videos_list">
            <div class="video-img-box"><a href="/videos/first/"></a>
              <div class="detail"><h6>First</h6></div>
            </div>
            <div class="video-img-box"><a href="/videos/second/"></a>
              <div class="detail"><h6>Second</h6></div>
            </div>
          </div>
        ''');
      }
      detailStarted.complete();
      return finishDetail.future;
    });
    final client = _client(adapter);
    final browse = client.browse('https://jable.tv/hot/');
    await detailStarted.future;

    await client.clearSession();
    finishDetail.complete(_html('<html><body>Late response</body></html>'));
    await expectLater(browse, throwsA(anything));

    expect(adapter.requests.map((request) => request.uri.path), [
      '/hot/',
      '/videos/first/',
    ]);
    client.dispose();
  });

  test('stops catalog enrichment if the locale changes mid-request', () async {
    final detailStarted = Completer<void>();
    final finishDetail = Completer<ResponseBody>();
    final adapter = _Adapter((request) async {
      if (request.uri.path == '/hot/') {
        return _html('''
          <div id="list_videos_hot_videos_list">
            <div class="video-img-box"><a href="/videos/first/"></a>
              <div class="detail"><h6>First</h6></div>
            </div>
            <div class="video-img-box"><a href="/videos/second/"></a>
              <div class="detail"><h6>Second</h6></div>
            </div>
          </div>
        ''');
      }
      detailStarted.complete();
      return finishDetail.future;
    });
    final client = _client(adapter);
    final browse = client.browse('https://jable.tv/hot/');
    await detailStarted.future;

    client.setLocale('ja-JP');
    finishDetail.complete(_html('<html><body>Late response</body></html>'));
    await expectLater(browse, throwsA(isA<VideoSourceException>()));

    expect(adapter.requests.map((request) => request.uri.path), [
      '/hot/',
      '/videos/first/',
    ]);
    client.dispose();
  });

  test(
    'stops stale filtered search during the first metadata request',
    () async {
      final detailStarted = Completer<void>();
      final finishDetail = Completer<ResponseBody>();
      final adapter = _Adapter((request) async {
        if (request.uri.path == '/search/needle/') {
          return _html('''
          <div id="list_videos_search_videos_list">
            <div class="video-img-box"><a href="/videos/first/"></a>
              <div class="detail"><h6>First</h6></div>
            </div>
            <div class="video-img-box"><a href="/videos/second/"></a>
              <div class="detail"><h6>Second</h6></div>
            </div>
          </div>
        ''');
        }
        detailStarted.complete();
        return finishDetail.future;
      });
      final client = _client(adapter);
      var current = true;
      final search = client.searchWithFilters(
        'needle',
        const [],
        isCurrent: () => current,
      );
      await detailStarted.future;

      current = false;
      finishDetail.complete(_html('<html><body>Late response</body></html>'));
      expect(await search, isEmpty);
      expect(adapter.requests.map((request) => request.uri.path), [
        '/search/needle/',
        '/videos/first/',
      ]);
      client.dispose();
    },
  );

  test('enriches related cards after the current video is ready', () async {
    VideoDetails? ready;
    final adapter = _Adapter((request) {
      if (request.uri.path == '/videos/current/') {
        return _html('''
          <html><body><div class="video-info">
            <div class="info-header"><span class="inactive-color">2025-01-01</span></div>
          </div>
          <div class="video-img-box"><a href="/videos/related/"></a>
            <div class="detail"><h6>Related card</h6></div>
          </div>
          <script>var hlsUrl = "https://media.example/current.m3u8";</script>
        </body></html>
        ''');
      }
      expect(ready!.streams, isNotEmpty);
      expect(ready!.related, isEmpty);
      return _html('''
        <html><head><meta property="og:title" content="Related title"></head>
        <body><div class="video-info">
          <div class="info-header"><span class="inactive-color">2025-01-02</span>
            <div class="models"><a class="model" href="/models/related-model/">
              <span class="rounded-circle" data-original-title="Related model"></span>
            </a></div>
          </div>
          <div class="tags"><a href="/tags/drama/">Drama</a></div>
        </div></body></html>
      ''');
    });
    final client = _client(adapter);

    final details = await client.details(
      const VideoItem(
        id: 'current',
        sourceKey: 'jable',
        title: 'Current',
        pageUrl: 'https://jable.tv/videos/current/',
      ),
      onReady: (value) => ready = value,
    );

    expect(ready!.streams.single.url, 'https://media.example/current.m3u8');
    expect(ready!.related, isEmpty);
    expect(details.related.single.title, 'Related title');
    expect(details.related.single.releaseDate, '2025-01-02');
    expect(details.related.single.actors.single.label, 'Related model');
    expect(details.related.single.tags.single.label, 'Drama');
    expect(adapter.requests.map((request) => request.uri.path), [
      '/videos/current/',
      '/videos/related/',
    ]);

    final unobserved = await client.details(
      const VideoItem(
        id: 'current',
        sourceKey: 'jable',
        title: 'Current',
        pageUrl: 'https://jable.tv/videos/current/',
      ),
      includeAccountState: false,
    );
    expect(unobserved.related.single.title, 'Related card');
    expect(unobserved.related.single.actors, isEmpty);
    expect(adapter.requests.map((request) => request.uri.path), [
      '/videos/current/',
      '/videos/related/',
      '/videos/current/',
    ]);
    client.dispose();
  });

  test(
    'adds a selected locale to document requests but not catalog URLs',
    () async {
      final adapter = _Adapter(
        (_) => _html('<html><body>Results</body></html>'),
      );
      final client = _client(adapter);

      expect(client.setLocale('ja-JP'), isTrue);
      final page = await client.search('sample title');

      expect(
        adapter.requests.single.uri.toString(),
        'https://jable.tv/search/sample%20title/?lang=jp',
      );
      expect(page.url, 'https://jable.tv/search/sample%20title/');
      expect(client.setLocale('ja'), isFalse);
      expect(client.setLocale('fr'), isFalse);
      expect(client.setLocale('en-US'), isTrue);
      await client.browse('https://jable.tv/hot/');
      expect(adapter.requests.last.uri.queryParameters['lang'], 'en');
      expect(client.setLocale('zh-Hant'), isTrue);
      await client.browse('https://jable.tv/hot/');
      expect(adapter.requests.last.uri.queryParameters['lang'], 'zh');
      client.dispose();
    },
  );

  test('leaves request URLs untouched when no locale is selected', () async {
    final adapter = _Adapter((_) => _html('<html><body>Results</body></html>'));
    final client = _client(adapter);

    final page = await client.browse(
      'https://jable.tv/hot/?from=1&sort_by=video_viewed_today',
    );

    expect(
      adapter.requests.single.uri.toString(),
      'https://jable.tv/hot/?from=1&sort_by=video_viewed_today',
    );
    expect(page.url, 'https://jable.tv/hot/?from=1&sort_by=video_viewed_today');
    client.dispose();
  });

  test(
    'parses the detail stream without copying site cookies to its CDN',
    () async {
      final adapter = _Adapter(
        (_) => _html('''
        <html><head>
          <meta property="og:title" content="Sample title">
          <meta property="og:image" content="https://img.example/cover.jpg">
        </head><body>
          <div class="video-info">
            <div class="info-header">
              <span class="inactive-color">上市於 2025-01-02</span>
              <span class="badge">无码</span>
              <div class="models">
                <a class="model" href="/models/sample-model/">
                  <span class="rounded-circle" data-original-title="Sample model"></span>
                </a>
              </div>
            </div>
            <div class="tags">
              <a class="cat" href="/categories/chinese-subtitle/">Chinese subtitle</a>
              <a href="/tags/drama/">Drama tag</a>
            </div>
            <h4>Detail description</h4>
          </div>
          <aside class="sidebar">
            <a href="/models/sidebar-model/">Sidebar model</a>
            <a href="/categories/sidebar-tag/">Sidebar tag</a>
            <span>无码推荐广告</span>
          </aside>
          <script>var hlsUrl = "https://media.example/stream/master.m3u8";</script>
        </body></html>
      '''),
      );
      final client = _client(adapter);

      final details = await client.details(
        const VideoItem(
          id: 'native-001',
          sourceKey: 'jable',
          title: 'Card title',
          pageUrl: 'https://jable.tv/videos/native-001/',
          durationSeconds: 7439,
          actors: [
            VideoLink(
              label: 'Known actor',
              url: 'https://jable.tv/models/known-actor/',
              kind: VideoLinkKind.actor,
            ),
          ],
          tags: [
            VideoLink(
              label: 'Known tag',
              url: 'https://jable.tv/tags/known-tag/',
              kind: VideoLinkKind.tag,
            ),
          ],
          makers: ['Known maker'],
        ),
      );

      expect(details.video.title, 'Sample title');
      expect(details.video.sourceKey, 'jable');
      expect(details.video.releaseDate, '2025-01-02');
      expect(details.video.hasSubtitles, isTrue);
      expect(details.video.isUncensored, isTrue);
      expect(details.video.durationSeconds, 7439);
      expect(details.video.actors.map((link) => link.label), [
        'Sample model',
        'Known actor',
      ]);
      expect(details.video.tags.map((link) => link.label), [
        'Chinese subtitle',
        'Drama tag',
        'Known tag',
      ]);
      expect(details.video.makers, ['Known maker']);
      expect(
        details.streams.single.url,
        'https://media.example/stream/master.m3u8',
      );
      expect(details.streams.single.headers, {
        'Referer': 'https://jable.tv/videos/native-001/',
      });
      expect(details.streams.single.headers.keys, isNot(contains('Cookie')));
      client.dispose();
    },
  );

  test(
    '403 and a 200 Cloudflare challenge both request browser verification',
    () async {
      for (final response in [
        _html('<html><body>Denied</body></html>', statusCode: 403),
        _html('''
        <!doctype html><html><head><title>Just a moment...</title></head>
        <body><div id="cf-challenge">Checking your browser</div></body></html>
      '''),
      ]) {
        final client = _client(_Adapter((_) => response));

        await expectLater(
          client.browse('https://jable.tv/'),
          throwsA(isA<JableVerificationRequiredException>()),
        );
        client.dispose();
      }
    },
  );

  test('rejects an unsupported page address instead of following it', () async {
    final client = _client(_Adapter((_) => _html('<html></html>')));

    await expectLater(
      client.browse('https://ads.example/categories/'),
      throwsA(isA<VideoSourceException>()),
    );
    client.dispose();
  });

  test(
    'clearing a session during import prevents a late verified session',
    () async {
      final writeStarted = Completer<void>();
      final allowWrite = Completer<void>();
      final storage = _MemorySecureStorage()
        ..beforeWrite = () async {
          writeStarted.complete();
          await allowWrite.future;
        };
      final dio = Dio();
      final client = JableClient(dio: dio, secureStorage: storage);
      final import = client.importVerifiedSession(
        cookieHeader: 'cf_clearance=verified',
        userAgent: 'Browser agent',
        expectedGeneration: client.sessionGeneration,
      );
      await writeStarted.future;

      final clear = client.clearSession();
      allowWrite.complete();
      await expectLater(import, throwsA(isA<StateError>()));
      await clear;

      expect(storage.values, isEmpty);
      client.dispose();
      dio.close(force: true);
    },
  );

  test(
    'restored browser access can browse before session restoration returns',
    () async {
      final storage = _MemorySecureStorage()
        ..values['jable_verified_session'] =
            '{"cookie":"cf_clearance=saved","userAgent":"Saved UA"}';
      final dio = Dio()
        ..httpClientAdapter = _Adapter(
          (_) =>
              _html('<html><head><title>Native fallback</title></head></html>'),
        );
      var documentNavigations = 0;
      final documentPaths = <String>[];
      final browser = MissavBrowserAdapter.jable(
        runJavaScript: (_) async {},
        currentUrl: () async => 'https://jable.tv/',
        navigateDocument: (uri, __) async {
          documentNavigations++;
          documentPaths.add(uri.path);
          if (uri.path.isEmpty || uri.path == '/') {
            return '''<html><body><div id="list_videos_home_videos_list">
              <div class="video-img-box"><a href="/videos/one/"></a>
                <div class="detail"><h6>One</h6></div>
              </div>
              <div class="video-img-box"><a href="/videos/two/"></a>
                <div class="detail"><h6>Two</h6></div>
              </div>
            </div></body></html>''';
          }
          return '<html><head><title>Restored browser</title></head></html>';
        },
        disposeBrowser: () async {},
      );
      final client = JableClient(
        dio: dio,
        secureStorage: storage,
        restoreSavedSession: (client, generation) async {
          client.useVerifiedBrowserTransport(
            browser,
            expectedGeneration: generation,
          );
          await client.checkBrowserAccess();
        },
      );

      final page = await client.browse('https://jable.tv/latest-updates/');

      expect(page.title, 'Restored browser');
      expect(documentNavigations, 2);
      expect(documentPaths, ['', '/latest-updates/']);
      client.dispose();
      dio.close(force: true);
    },
  );
}

JableClient _client(_Adapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return JableClient(dio: dio, secureStorage: _MemorySecureStorage());
}

ResponseBody _html(String body, {int statusCode = 200}) =>
    ResponseBody.fromString(body, statusCode);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final response = Future<ResponseBody>.sync(() => respond(options));
    if (cancelFuture == null) return response;
    return Future.any([
      response,
      cancelFuture.then<ResponseBody>(
        (_) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          message: 'Request cancelled by test',
        ),
      ),
    ]);
  }

  @override
  void close({bool force = false}) {}
}

class _MemorySecureStorage implements FlutterSecureStorage {
  final values = <String, String>{};
  Future<void> Function()? beforeWrite;

  Future<void> _write(String key, String value) async {
    await beforeWrite?.call();
    values[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) {
      return Future<String?>.value(
        values[invocation.namedArguments[#key] as String],
      );
    }
    if (invocation.memberName == #write) {
      return _write(
        invocation.namedArguments[#key] as String,
        invocation.namedArguments[#value] as String,
      );
    }
    if (invocation.memberName == #delete) {
      return Future<void>.sync(() {
        values.remove(invocation.namedArguments[#key] as String);
      });
    }
    return super.noSuchMethod(invocation);
  }
}

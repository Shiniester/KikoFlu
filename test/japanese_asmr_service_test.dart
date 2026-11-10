import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/japanese_asmr_browse.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/models/sort_options.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/services/audio_track_queue_builder.dart';
import 'package:kikoeru_flutter/src/services/japanese_asmr_service.dart';

class _Reply {
  const _Reply(
    this.body, {
    this.statusCode = 200,
    this.contentType = 'application/json',
    this.headers = const {},
  });

  final Object body;
  final int statusCode;
  final String contentType;
  final Map<String, List<String>> headers;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final FutureOr<_Reply> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final reply = await respond(options);
    return ResponseBody.fromString(
      reply.body is String ? reply.body as String : jsonEncode(reply.body),
      reply.statusCode,
      headers: {
        'content-type': [reply.contentType],
        ...reply.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _item({
  int workId = 150867,
  String rj = 'RJ01707048',
  String title = 'Eara work',
  List<dynamic>? tagDetails,
}) => {
  'workId': workId,
  'rj': rj,
  'title': title,
  'circle': 'Circle',
  'cvs': ['Voice'],
  'tags': ['Ear cleaning'],
  'tagDetails':
      tagDetails ??
      [
        {'name': 'Ear cleaning'},
      ],
  'releaseDate': '2026-01-02',
  'publishedAt': '2026-01-03',
  'mainCoverUrl': 'https://images.example/cover.jpg',
  'pageUrl': 'https://japaneseasmr.com/150867/',
  'allAges': false,
  'source': 'jp-asmr',
};

Map<String, dynamic> _searchResponse(List<Map<String, dynamic>> items) => {
  'items': items,
  'total': items.length,
  'limit': 20,
  'offset': 0,
  'sort': 'release',
};

Dio _dio(_Adapter adapter, {Map<String, dynamic>? headers}) =>
    Dio(BaseOptions(headers: headers ?? const {}))..httpClientAdapter = adapter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'search maps Eara records and preserves legacy negative work IDs',
    () async {
      final adapter = _Adapter(
        (_) => _Reply(_searchResponse([_item(tagDetails: [])])),
      );
      final dio = _dio(
        adapter,
        headers: {
          'Authorization': 'Bearer private',
          'Cookie': 'session=private',
        },
      );
      final service = JapaneseAsmrService(dio: dio);

      final response = await service.searchWorks(
        keyword: 'ear & voice',
        page: 2,
        pageSize: 1,
      );

      final request = adapter.requests.single;
      expect(request.uri.host, 'earaasmr.com');
      expect(request.uri.path, '/api/jp-asmr/search');
      expect(request.uri.queryParameters, {
        'q': 'ear & voice',
        'limit': '1',
        'offset': '1',
        'sort': 'release',
      });
      expect(request.headers['Accept'], 'application/json');
      expect(
        request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains(anyOf('authorization', 'cookie'))),
      );

      final works = response['works'] as List<Map<String, dynamic>>;
      expect(works.single['id'], -150867);
      expect(works.single['source_id'], 'RJ01707048');
      expect(works.single['name'], 'Circle');
      expect(works.single['cover_url'], 'https://images.example/cover.jpg');
      expect(works.single['release'], '2026-01-02');
      expect(works.single.containsKey('age'), isFalse);
      expect((works.single['tags'] as List).single['name'], 'Ear cleaning');
      expect(Work.fromJson(works.single).displayId, 'RJ01707048');
      expect(response['pagination'], {
        'currentPage': 2,
        'pageSize': 1,
        'totalCount': 1,
        'hasMore': false,
      });
      expect(service.hasRegisteredWork(150867), isTrue);
    },
  );

  test('home supports release order and the Eara all-ages filter', () async {
    final adapter = _Adapter((_) => _Reply(_searchResponse([_item()])));
    final service = JapaneseAsmrService(dio: _dio(adapter));

    await service.getWorks(
      page: 1,
      pageSize: 10,
      ageRating: AgeRating.general,
      sort: JapaneseAsmrSortOption.date,
      direction: SortDirection.desc,
    );

    expect(adapter.requests.single.uri.queryParameters, {
      'q': '',
      'limit': '10',
      'offset': '0',
      'sort': 'release',
      'allAges': 'true',
    });
  });

  test(
    'keyword search passes the all-ages filter separately from keywords',
    () async {
      final adapter = _Adapter((_) => _Reply(_searchResponse([])));
      final service = JapaneseAsmrService(dio: _dio(adapter));
      await service.searchWorks(
        keyword: '耳かき',
        page: 1,
        pageSize: 20,
        ageRating: AgeRating.general,
      );
      expect(adapter.requests.single.uri.queryParameters['q'], '耳かき');
      expect(adapter.requests.single.uri.queryParameters['allAges'], 'true');
      await expectLater(
        service.searchWorks(
          keyword: '',
          page: 1,
          pageSize: 20,
          ageRating: AgeRating.adult,
        ),
        throwsUnsupportedError,
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'search keeps original tag names and attaches localized details',
    () async {
      final item = _item(
        tagDetails: [
          {
            'key': 'asmr-one:tag:68',
            'originalName': 'Ear cleaning',
            'names': {'en': 'Ear cleaning', 'ja': '耳かき'},
          },
          {'key': 'dlsite:genre:068', 'originalName': 'Ear cleaning'},
        ],
      );
      final fallback = _item(workId: 150868, rj: 'RJ01707049')
        ..['tags'] = <String>[]
        ..['tagDetails'] = [
          {'originalName': 'Relaxation'},
        ];
      final adapter = _Adapter(
        (_) => _Reply(_searchResponse([item, fallback])),
      );
      final service = JapaneseAsmrService(dio: _dio(adapter));

      final response = await service.searchWorks(
        keyword: '',
        page: 1,
        pageSize: 20,
      );
      final works = response['works'] as List<Map<String, dynamic>>;

      expect(Work.fromJson(works[0]).tags!.map((tag) => tag.name), [
        'Ear cleaning',
      ]);
      final tag = Work.fromJson(works[0]).tags!.single;
      expect(tag.names, {'en': 'Ear cleaning', 'ja': '耳かき'});
      expect(Tag.fromJson(tag.toJson()), tag);
      expect(Work.fromJson(works[1]).tags!.map((tag) => tag.name), [
        'Relaxation',
      ]);
    },
  );

  test(
    'home rejects unsupported rating and ordering without a request',
    () async {
      final adapter = _Adapter((_) => _Reply(_searchResponse([])));
      final service = JapaneseAsmrService(dio: _dio(adapter));

      await expectLater(
        service.getWorks(page: 1, pageSize: 10, ageRating: AgeRating.adult),
        throwsUnsupportedError,
      );
      await expectLater(
        service.getWorks(
          page: 1,
          pageSize: 10,
          sort: JapaneseAsmrSortOption.popular,
        ),
        throwsUnsupportedError,
      );
      expect(adapter.requests, isEmpty);
    },
  );

  test(
    'keyword search rejects source-site filters instead of faking them',
    () async {
      final adapter = _Adapter((_) => _Reply(_searchResponse([])));
      final service = JapaneseAsmrService(dio: _dio(adapter));

      await expectLater(
        service.searchWorks(
          keyword: '',
          page: 1,
          pageSize: 20,
          conditions: const [
            SearchCondition(
              id: 'tag',
              type: SearchType.tag,
              value: 'Ear cleaning',
            ),
          ],
        ),
        throwsUnsupportedError,
      );
      expect(adapter.requests, isEmpty);
    },
  );

  test(
    'getWork looks up the registered source ID and returns the exact work',
    () async {
      final adapter = _Adapter((request) {
        expect(request.uri.path, '/api/jp-asmr/search');
        return _Reply(
          _searchResponse([_item(workId: 42, rj: 'RJ01707048'), _item()]),
        );
      });
      final service = JapaneseAsmrService(dio: _dio(adapter));
      service.registerWork(
        const Work(id: -150867, title: 'Eara work', sourceId: 'rj01707048'),
      );

      final work = Work.fromJson(await service.getWork(150867));

      expect(adapter.requests.single.uri.queryParameters, {
        'q': 'RJ01707048',
        'limit': '20',
        'offset': '0',
        'sort': 'release',
      });
      expect(work.id, -150867);
      expect(work.sourceId, 'RJ01707048');
    },
  );

  test(
    'registerWork exposes title-only legacy mapping and recovers exact source ID',
    () async {
      final target = _item(title: 'Exact legacy title');
      final unrelated = _item(
        workId: 42,
        rj: 'RJ00000042',
        title: 'Exact legacy title',
      );
      final adapter = _Adapter(
        (_) => _Reply(_searchResponse([unrelated, target])),
      );
      final service = JapaneseAsmrService(dio: _dio(adapter));
      service.registerWork(
        const Work(
          id: -150867,
          title: 'Exact legacy title',
          sourceId: 'JP-150867',
        ),
      );

      expect(service.hasRegisteredWork(150867), isTrue);
      expect(service.hasRegisteredWork(-150867), isFalse);
      final work = Work.fromJson(await service.getWork(150867));

      expect(adapter.requests.single.uri.queryParameters, {
        'q': 'Exact legacy title',
        'limit': '20',
        'offset': '0',
        'sort': 'release',
      });
      expect(work.id, -150867);
      expect(work.sourceId, 'RJ01707048');
    },
  );

  test('title recovery fails when Eara returns no exact page ID', () async {
    final adapter = _Adapter(
      (_) => _Reply(
        _searchResponse([
          _item(workId: 42, rj: 'RJ00000042', title: 'Similar legacy title'),
        ]),
      ),
    );
    final service = JapaneseAsmrService(dio: _dio(adapter));
    service.registerWork(
      const Work(id: -150867, title: 'Legacy title', sourceId: 'JP-150867'),
    );

    await expectLater(service.getWork(150867), throwsFormatException);
    expect(adapter.requests, hasLength(1));
  });

  test(
    'tracks map Eara chapter ranges to the existing playback and download shape',
    () async {
      final adapter = _Adapter((request) {
        if (request.uri.path.endsWith('/search')) {
          return _Reply(_searchResponse([_item()]));
        }
        return const _Reply({
          'rj': 'RJ01707048',
          'workId': 150867,
          'pageUrl': 'https://japaneseasmr.com/150867/',
          'fetchedAt': '2026-01-04T00:00:00Z',
          'trackTree': [
            {
              'type': 'folder',
              'title': 'Main',
              'children': [
                {
                  'type': 'audio',
                  'title': 'RJ01707048_001.m4a',
                  'duration': 106,
                  'streamUrl':
                      'https://v.weeab0o.xyz/RJ01707048.m3u8#eara-chapter=0,106000&file=RJ01707048_001.m4a',
                  'mediaDownloadUrl': 'https://ts.buzzheavier.com/d/full-file',
                },
                {
                  'type': 'audio',
                  'title': 'RJ01707048_002.mp3',
                  'duration': 90,
                  'streamUrl':
                      'https://v.weeab0o.xyz/RJ01707048.m3u8#eara-chapter=106000,&file=RJ01707048_002.mp3',
                  'mediaDownloadUrl':
                      'https://ts.buzzheavier.com/d/second-file',
                },
                {
                  'type': 'audio',
                  'title': 'd_353674.mp3',
                  'duration': 55,
                  'streamUrl':
                      'https://v.weeab0o.xyz/d_353674.mp3#eara-chapter=0,',
                },
                {
                  'type': 'audio',
                  'title': 'direct-only.mp3',
                  'mediaDownloadUrl': 'https://files.example/direct-only.mp3',
                },
              ],
            },
          ],
        });
      });
      final service = JapaneseAsmrService(dio: _dio(adapter));
      service.registerWork(
        const Work(id: -150867, title: 'Eara work', sourceId: 'RJ01707048'),
      );

      final tree = await service.getWorkTracks(150867);
      final folder = tree.single as Map<String, dynamic>;
      final tracks = folder['children'] as List<Map<String, dynamic>>;

      expect(adapter.requests.map((request) => request.uri.path), [
        '/api/jp-asmr/search',
        '/api/jp-asmr/tracks',
      ]);
      expect(adapter.requests.last.uri.queryParameters, {'rj': 'RJ01707048'});
      expect(tracks.map((track) => track['title']), [
        '1_RJ01707048_001.aac',
        '2_RJ01707048_002.aac',
        'd_353674.mp3',
        'direct-only.mp3',
      ]);
      expect(tracks.map((track) => track['hash']), [
        'jp-150867-chapter-0',
        'jp-150867-chapter-106000',
        'jp-150867-file-3',
        'jp-150867-file-4',
      ]);
      expect(tracks.take(2).map((track) => track['startTimeMs']), [0, 106000]);
      expect(tracks.take(2).map((track) => track['originalDownloadUrl']), [
        'https://ts.buzzheavier.com/d/full-file',
        'https://ts.buzzheavier.com/d/second-file',
      ]);
      expect(tracks.take(2).map((track) => track['endTimeMs']), [106000, null]);
      expect(tracks.last.containsKey('startTimeMs'), isFalse);
      expect(tracks.last.containsKey('endTimeMs'), isFalse);
      expect(tracks.map((track) => track['mediaStreamUrl']), [
        'https://v.weeab0o.xyz/RJ01707048.m3u8',
        'https://v.weeab0o.xyz/RJ01707048.m3u8',
        'https://v.weeab0o.xyz/d_353674.mp3',
        'https://files.example/direct-only.mp3',
      ]);
      expect(tracks.map((track) => track['mediaDownloadUrl']), [
        'https://v.weeab0o.xyz/RJ01707048.m3u8',
        'https://v.weeab0o.xyz/RJ01707048.m3u8',
        'https://v.weeab0o.xyz/d_353674.mp3',
        'https://files.example/direct-only.mp3',
      ]);

      final queue = await const AudioTrackQueueBuilder().build(
        audioFiles: tracks,
        selectedFile: tracks.first,
        resolveUrl: (file) async => (file as Map)['mediaStreamUrl'] as String,
        workId: -150867,
        albumTitle: 'Eara work',
        unknownTitle: 'Unknown',
      );
      expect(queue.tracks.first.url, 'https://v.weeab0o.xyz/RJ01707048.m3u8');
      expect(queue.tracks.first.startTimeMs, 0);
      expect(queue.tracks.first.endTimeMs, 106000);
      expect(queue.tracks[1].endTimeMs, isNull);
      expect(queue.tracks.last.startTimeMs, isNull);
    },
  );

  test('rejects malformed non-empty Eara chapter ends', () async {
    final adapter = _Adapter((request) {
      if (request.uri.path.endsWith('/search')) {
        return _Reply(_searchResponse([_item()]));
      }
      return const _Reply({
        'rj': 'RJ01707048',
        'workId': 150867,
        'trackTree': [
          {
            'type': 'audio',
            'title': 'bad.m4a',
            'streamUrl':
                'https://v.weeab0o.xyz/RJ01707048.m3u8#eara-chapter=0,nope',
          },
        ],
      });
    });
    final service = JapaneseAsmrService(dio: _dio(adapter));
    service.registerWork(
      const Work(id: -150867, title: 'Eara work', sourceId: 'RJ01707048'),
    );

    await expectLater(service.getWorkTracks(150867), throwsFormatException);
  });

  test('rejects ranged metadata on a non-HLS Eara audio URL', () async {
    final adapter = _Adapter((request) {
      if (request.uri.path.endsWith('/search')) {
        return _Reply(_searchResponse([_item()]));
      }
      return const _Reply({
        'rj': 'RJ01707048',
        'workId': 150867,
        'trackTree': [
          {
            'type': 'audio',
            'title': 'partial.mp3',
            'streamUrl':
                'https://v.weeab0o.xyz/partial.mp3#eara-chapter=106000,',
          },
        ],
      });
    });
    final service = JapaneseAsmrService(dio: _dio(adapter));
    service.registerWork(
      const Work(id: -150867, title: 'Eara work', sourceId: 'RJ01707048'),
    );

    await expectLater(service.getWorkTracks(150867), throwsFormatException);
  });

  test('registers UN and UND source IDs for Eara lookups', () async {
    for (final sourceId in ['UN00000001', 'UND00000002']) {
      final adapter = _Adapter((request) {
        if (request.uri.path.endsWith('/search')) {
          return _Reply(_searchResponse([_item(rj: sourceId)]));
        }
        return _Reply({
          'rj': sourceId,
          'workId': 150867,
          'trackTree': <dynamic>[],
        });
      });
      final service = JapaneseAsmrService(dio: _dio(adapter));
      service.registerWork(
        Work(id: -150867, title: 'Eara work', sourceId: sourceId),
      );

      await service.getWorkTracks(150867);

      expect(adapter.requests.last.uri.queryParameters['rj'], sourceId);
    }
  });

  test('rejects an unmapped page ID before making an Eara request', () async {
    final adapter = _Adapter((_) => _Reply(_searchResponse([])));
    final service = JapaneseAsmrService(dio: _dio(adapter));

    await expectLater(service.getWork(150867), throwsFormatException);
    await expectLater(service.getWorkTracks(150867), throwsFormatException);
    expect(adapter.requests, isEmpty);
  });

  test(
    'resolves queued source-site download links through Eara and Buzzheavier',
    () async {
      final adapter = _Adapter((request) {
        if (request.uri.path == '/api/jp-asmr/tracks') {
          return const _Reply({
            'rj': 'RJ01707048',
            'workId': 150867,
            'trackTree': [
              {
                'type': 'audio',
                'title': 'RJ01707048.m4a',
                'mediaDownloadUrl': 'https://buzzheavier.com/file',
              },
            ],
          });
        }
        if (request.uri.path == '/file') {
          return const _Reply(
            '<a class="download-btn" hx-get="/file/download">Download</a>',
            contentType: 'text/html',
          );
        }
        return const _Reply(
          '',
          contentType: 'text/plain',
          headers: {
            'hx-redirect': ['https://cdn.example/audio.m4a?token=fresh'],
          },
        );
      });
      final service = JapaneseAsmrService(dio: _dio(adapter));

      expect(
        await service.resolveDownloadUrl(
          'https://japaneseasmr.com/dlc.php?f=RJ01707048',
        ),
        'https://cdn.example/audio.m4a?token=fresh',
      );
      expect(adapter.requests.map((request) => request.uri.host), [
        'earaasmr.com',
        'buzzheavier.com',
        'buzzheavier.com',
      ]);
      await expectLater(
        service.resolveDownloadUrl('https://japaneseasmr.com/150867/'),
        throwsFormatException,
      );
      expect(adapter.requests, hasLength(3));
      expect(adapter.requests.last.headers['HX-Request'], 'true');
      expect(
        adapter.requests.last.headers['Referer'],
        'https://buzzheavier.com/file',
      );
    },
  );

  test('does not treat Eara chapters as a queued full-work download', () async {
    final adapter = _Adapter(
      (_) => const _Reply({
        'rj': 'RJ01707048',
        'trackTree': [
          {
            'type': 'audio',
            'title': 'RJ01707048_001.m4a',
            'mediaDownloadUrl': 'https://files.example/one.m4a',
          },
          {
            'type': 'audio',
            'title': 'RJ01707048_002.m4a',
            'mediaDownloadUrl': 'https://files.example/two.m4a',
          },
        ],
      }),
    );
    final service = JapaneseAsmrService(dio: _dio(adapter));

    await expectLater(
      service.resolveDownloadUrl(
        'https://japaneseasmr.com/dlc.php?f=RJ01707048',
      ),
      throwsFormatException,
    );
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.uri.host, 'earaasmr.com');
  });

  test('does not treat a bounded chapter as a full-work download', () async {
    final adapter = _Adapter(
      (_) => const _Reply({
        'rj': 'RJ01707048',
        'trackTree': [
          {
            'type': 'audio',
            'title': 'RJ01707048.m4a',
            'streamUrl':
                'https://media.example/work.m3u8#eara-chapter=0,106000',
            'mediaDownloadUrl': 'https://files.example/chapter.m4a',
          },
        ],
      }),
    );
    final service = JapaneseAsmrService(dio: _dio(adapter));

    await expectLater(
      service.resolveDownloadUrl(
        'https://japaneseasmr.com/dlc.php?f=RJ01707048',
      ),
      throwsFormatException,
    );
  });

  test(
    'propagates cancel and rejects unavailable media-host downloads',
    () async {
      final started = Completer<void>();
      final adapter = _Adapter((request) async {
        started.complete();
        await request.cancelToken!.whenCancel;
        return const _Reply('<a href="#">none</a>', contentType: 'text/html');
      });
      final service = JapaneseAsmrService(dio: _dio(adapter));
      final cancelToken = CancelToken();
      final result = service.resolveDownloadUrl(
        'https://buzzheavier.com/file',
        cancelToken: cancelToken,
      );
      final check = expectLater(
        result,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await started.future;
      cancelToken.cancel();
      await check;
      await expectLater(
        service.resolveDownloadUrl('https://media.example/work.m3u8'),
        throwsFormatException,
      );
    },
  );

  test('preserves HTTP status failures as DioException', () async {
    final adapter = _Adapter(
      (_) => const _Reply({'error': 'server down'}, statusCode: 503),
    );
    final service = JapaneseAsmrService(dio: _dio(adapter));
    await expectLater(
      service.searchWorks(keyword: 'test', page: 1, pageSize: 10),
      throwsA(
        isA<DioException>().having(
          (error) => error.response?.statusCode,
          'statusCode',
          503,
        ),
      ),
    );
  });

  test(
    'does not claim a related-work endpoint that Eara does not provide',
    () async {
      final adapter = _Adapter((_) => _Reply(_searchResponse([])));
      final service = JapaneseAsmrService(dio: _dio(adapter));

      await expectLater(
        service.getRelatedWorks(150867),
        throwsUnsupportedError,
      );
      expect(adapter.requests, isEmpty);
    },
  );
}

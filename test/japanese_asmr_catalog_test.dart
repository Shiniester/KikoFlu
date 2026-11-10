import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/services/japanese_asmr_service.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter({this.statusCode = 200});
  final int statusCode;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'hotTags': [
          {
            'value': '耳かき',
            'count': 8,
            'tagDetails': [
              {
                'originalName': '耳かき',
                'names': {'zh-CN': '耳搔', 'en': 'Ear cleaning'},
              },
            ],
          },
        ],
        'hotCvs': [
          {'value': 'Voice', 'count': 3},
        ],
      }),
      statusCode,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'catalog merges Eara suggestions with loaded work names and translations',
    () async {
      final adapter = _Adapter();
      final service = JapaneseAsmrService(
        dio: Dio(
          BaseOptions(
            headers: {'Authorization': 'private', 'Cookie': 'private'},
          ),
        )..httpClientAdapter = adapter,
      );

      service.registerWork(
        const Work(
          id: -1,
          title: 'Work',
          name: 'Circle',
          tags: [
            Tag(id: -1, name: '耳かき', names: {'ja': '耳かき'}),
            Tag(id: -2, name: '囁き', names: {'zh-CN': '耳语'}),
          ],
        ),
      );
      final tags = await service.getSearchCatalog(SearchType.tag);
      expect(tags.map((tag) => tag['name']), ['耳かき', '囁き']);
      expect(tags.first['names'], {
        'ja': '耳かき',
        'zh-CN': '耳搔',
        'en': 'Ear cleaning',
      });
      expect(tags.first['count'], 8);
      expect(
        (await service.getSearchCatalog(SearchType.va)).single['name'],
        'Voice',
      );
      expect(
        (await service.getSearchCatalog(SearchType.circle)).single['name'],
        'Circle',
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.uri.path, '/api/search-suggestions');
      expect(
        adapter.requests.single.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains(anyOf('authorization', 'cookie'))),
      );
      service.registerWork(
        const Work(
          id: -2,
          title: 'Later work',
          tags: [Tag(id: -1, name: '睡眠')],
        ),
      );
      expect(
        (await service.getSearchCatalog(
          SearchType.tag,
        )).map((tag) => tag['name']),
        contains('睡眠'),
      );
    },
  );

  test(
    'known work tags remain searchable when suggestions are unavailable',
    () async {
      final adapter = _Adapter(statusCode: 503);
      final service = JapaneseAsmrService(
        dio: Dio()..httpClientAdapter = adapter,
      );
      service.registerWork(
        const Work(
          id: -1,
          title: 'Work',
          tags: [Tag(id: -1, name: '耳かき')],
        ),
      );
      expect(
        (await service.getSearchCatalog(SearchType.tag)).single['name'],
        '耳かき',
      );
      final cancellation = CancelToken()..cancel();
      await expectLater(
        service.getSearchCatalog(SearchType.tag, cancelToken: cancellation),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
    },
  );
}

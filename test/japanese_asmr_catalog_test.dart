import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/services/japanese_asmr_service.dart';

class _Adapter implements HttpClientAdapter {
  var requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString('{}', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('does not request unsupported source-site search catalogs', () async {
    final adapter = _Adapter();
    final service = JapaneseAsmrService(
      dio: Dio()..httpClientAdapter = adapter,
    );

    for (final type in [SearchType.tag, SearchType.va, SearchType.circle]) {
      await expectLater(service.getSearchCatalog(type), throwsUnsupportedError);
    }
    expect(adapter.requests, 0);
  });
}

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/services/japanese_asmr_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';

class _JapaneseAsmrService extends JapaneseAsmrService {
  int? workId;
  CancelToken? listCancelToken;
  CancelToken? searchCancelToken;

  @override
  Future<Map<String, dynamic>> getWorks({
    required int page,
    required int pageSize,
    CancelToken? cancelToken,
  }) async {
    listCancelToken = cancelToken;
    return {'works': <dynamic>[], 'pagination': <String, dynamic>{}};
  }

  @override
  Future<Map<String, dynamic>> searchWorks({
    required String keyword,
    required int page,
    required int pageSize,
    CancelToken? cancelToken,
  }) async {
    searchCancelToken = cancelToken;
    return {'works': <dynamic>[], 'pagination': <String, dynamic>{}};
  }

  @override
  Future<Map<String, dynamic>> getWork(
    int postId, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    workId = postId;
    return {'id': -postId};
  }

  @override
  Future<List<dynamic>> getWorkTracks(
    int postId, {
    bool forceRefresh = false,
  }) async {
    workId = postId;
    return const [];
  }
}

void main() {
  test(
    'facade routes explicit Japanese requests and negative work IDs',
    () async {
      final japanese = _JapaneseAsmrService();
      final api = KikoeruApiService(japaneseAsmrService: japanese);
      final cancelToken = CancelToken();

      await api.getWorks(
        page: 2,
        pageSize: 20,
        source: AudioSource.jpAsmr,
        cancelToken: cancelToken,
      );
      await api.searchWorks(
        keyword: 'RJ01726738',
        source: AudioSource.jpAsmr,
        cancelToken: cancelToken,
      );
      final work = await api.getWork(-1726738, cancelToken: cancelToken);
      await api.getWorkTracks(-1726738);

      expect(japanese.listCancelToken, same(cancelToken));
      expect(japanese.searchCancelToken, same(cancelToken));
      expect(work['id'], -1726738);
      expect(japanese.workId, 1726738);
    },
  );
}

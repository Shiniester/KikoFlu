import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/japanese_asmr_browse.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/models/sort_options.dart';
import 'package:kikoeru_flutter/src/services/japanese_asmr_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';

class _JapaneseAsmrService extends JapaneseAsmrService {
  int? workId;
  CancelToken? listCancelToken;
  CancelToken? searchCancelToken;
  CancelToken? catalogCancelToken;
  SearchType? catalogType;
  JapaneseAsmrSortOption? sort;
  SortDirection? direction;
  JapaneseAsmrPeriod? period;
  int? archiveYear;
  int? archiveMonth;
  List<SearchCondition> searchConditions = const [];
  final relatedWorkIds = <int>[];

  @override
  Future<Map<String, dynamic>> getWorks({
    required int page,
    required int pageSize,
    JapaneseAsmrSortOption? sort,
    SortDirection direction = SortDirection.desc,
    JapaneseAsmrPeriod period = JapaneseAsmrPeriod.week,
    int? archiveYear,
    int? archiveMonth,
    CancelToken? cancelToken,
  }) async {
    this.sort = sort;
    this.direction = direction;
    this.period = period;
    this.archiveYear = archiveYear;
    this.archiveMonth = archiveMonth;
    listCancelToken = cancelToken;
    return {'works': <dynamic>[], 'pagination': <String, dynamic>{}};
  }

  @override
  Future<Map<String, dynamic>> searchWorks({
    required String keyword,
    required int page,
    required int pageSize,
    List<SearchCondition> conditions = const [],
    CancelToken? cancelToken,
  }) async {
    searchCancelToken = cancelToken;
    searchConditions = conditions;
    return {'works': <dynamic>[], 'pagination': <String, dynamic>{}};
  }

  @override
  Future<List<Map<String, dynamic>>> getSearchCatalog(
    SearchType type, {
    CancelToken? cancelToken,
  }) async {
    catalogType = type;
    catalogCancelToken = cancelToken;
    return const [];
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

  @override
  Future<List<dynamic>> getRelatedWorks(int postId) async {
    relatedWorkIds.add(postId);
    return [
      {'id': -postId},
    ];
  }
}

void main() {
  test(
    'facade routes explicit Japanese requests and negative work IDs',
    () async {
      final japanese = _JapaneseAsmrService();
      final api = KikoeruApiService(japaneseAsmrService: japanese);
      final cancelToken = CancelToken();
      const category = SearchCondition(
        id: 'catalog',
        type: SearchType.tag,
        value: 'Binaural',
        sourcePath: '/tag/binaural/',
      );

      await api.getWorks(
        page: 2,
        pageSize: 20,
        source: AudioSource.jpAsmr,
        japaneseAsmrSort: JapaneseAsmrSortOption.popular,
        japaneseAsmrDirection: SortDirection.asc,
        japaneseAsmrPeriod: JapaneseAsmrPeriod.archiveMonth,
        japaneseAsmrArchiveYear: 2026,
        japaneseAsmrArchiveMonth: 1,
        cancelToken: cancelToken,
      );
      await api.getSearchCatalog(SearchType.va, cancelToken: cancelToken);
      await api.searchWorks(
        keyword: 'RJ01726738',
        source: AudioSource.jpAsmr,
        conditions: [category],
        cancelToken: cancelToken,
      );
      final work = await api.getWork(-1726738, cancelToken: cancelToken);
      await api.getWorkTracks(-1726738);
      final related = await api.getRelatedWorks(-1726738);
      final asmrOneRelated = await api.getRelatedWorks(1726738);

      expect(japanese.listCancelToken, same(cancelToken));
      expect(japanese.sort, JapaneseAsmrSortOption.popular);
      expect(japanese.direction, SortDirection.asc);
      expect(japanese.period, JapaneseAsmrPeriod.archiveMonth);
      expect(japanese.archiveYear, 2026);
      expect(japanese.archiveMonth, 1);
      expect(japanese.searchCancelToken, same(cancelToken));
      expect(japanese.searchConditions, [category]);
      expect(japanese.catalogType, SearchType.va);
      expect(japanese.catalogCancelToken, same(cancelToken));
      expect(work['id'], -1726738);
      expect(japanese.workId, 1726738);
      expect(related, [
        {'id': -1726738},
      ]);
      expect(asmrOneRelated, isEmpty);
      expect(japanese.relatedWorkIds, [1726738]);
    },
  );
}

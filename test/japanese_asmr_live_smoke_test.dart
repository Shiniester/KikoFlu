import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/services/japanese_asmr_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Eara returns a work and its track tree',
    () async {
      HttpOverrides.global = null;
      final service = JapaneseAsmrService();
      final result = await service.searchWorks(
        keyword: 'RJ01707048',
        page: 1,
        pageSize: 10,
      );
      final works = (result['works'] as List)
          .map((item) => Work.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();
      final work = works.singleWhere((item) => item.sourceId == 'RJ01707048');

      expect(work.id, lessThan(0));
      expect(work.tags, isNotEmpty);
      expect((await service.getWork(work.id.abs()))['id'], work.id);
      final tree = await service.getWorkTracks(work.id.abs());
      final children = (tree.single as Map)['children'] as List;
      expect(
        children.where(
          (item) =>
              item is Map &&
              item['type'] == 'audio' &&
              (item['mediaStreamUrl'] as String?)?.startsWith('https://') ==
                  true,
        ),
        isNotEmpty,
      );
    },
    skip: Platform.environment['KIKOFLU_LIVE_JP_ASMR'] != '1',
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/services/scoped_search_matcher.dart';

void main() {
  Work work({
    int id = 12345,
    String title = 'Quiet Night',
    String? circle = 'Moon Circle',
    List<Tag>? tags = const [Tag(id: 1, name: 'Relaxing')],
    List<Va>? vas = const [Va(id: 'va-1', name: 'Voice A')],
    String? age = 'general',
    double? rate = 4.25,
    int? sales = 500,
    String? sourceId,
  }) => Work(
    id: id,
    title: title,
    name: circle,
    tags: tags,
    vas: vas,
    age: age,
    rateAverage: rate,
    dlCount: sales,
    sourceId: sourceId,
  );

  SearchQuery query(
    List<SearchCondition> conditions, {
    double minRate = 0,
    AgeRating ageRating = AgeRating.all,
    SalesRange salesRange = SalesRange.all,
  }) => SearchQuery(
    scope: SearchScope.history,
    conditions: conditions,
    minRate: minRate,
    ageRating: ageRating,
    salesRange: salesRange,
  );

  SearchCondition condition(
    SearchType type,
    String value, {
    bool exclude = false,
  }) => SearchCondition(
    id: '$type:$value:$exclude',
    type: type,
    value: value,
    isExclude: exclude,
  );

  test('positive conditions are conjunctive and exclusions remove matches', () {
    final value = work();
    expect(
      matchesSearchQuery(
        value,
        query([
          condition(SearchType.keyword, 'quiet'),
          condition(SearchType.tag, 'relax'),
        ]),
      ),
      isTrue,
    );
    expect(
      matchesSearchQuery(
        value,
        query([
          condition(SearchType.keyword, 'quiet'),
          condition(SearchType.tag, 'dramatic'),
        ]),
      ),
      isFalse,
    );
    expect(
      matchesSearchQuery(
        value,
        query([
          condition(SearchType.keyword, 'quiet'),
          condition(SearchType.tag, 'relax', exclude: true),
        ]),
      ),
      isFalse,
    );
  });

  test('RJ input matches normalized local ids and alternate display ids', () {
    expect(
      matchesSearchQuery(
        work(),
        query([condition(SearchType.rjNumber, 'RJ12345')]),
      ),
      isTrue,
    );
    expect(
      matchesSearchQuery(
        work(id: 7, sourceId: 'VJ00012345'),
        query([condition(SearchType.rjNumber, '12345')]),
      ),
      isFalse,
    );
    expect(
      matchesSearchQuery(
        work(id: 7, sourceId: 'RJ0012345'),
        query([condition(SearchType.rjNumber, '12345')]),
      ),
      isTrue,
    );
  });

  test('RJ input does not match internal ids when a source id is present', () {
    for (final sourceId in ['RJ0012345', 'BJ0000007', 'VJ0000007']) {
      expect(
        matchesSearchQuery(
          work(id: 7, sourceId: sourceId),
          query([condition(SearchType.rjNumber, 'RJ7')]),
        ),
        isFalse,
        reason: sourceId,
      );
    }
    for (final sourceId in [null, '   ']) {
      expect(
        matchesSearchQuery(
          work(id: 7, sourceId: sourceId),
          query([condition(SearchType.rjNumber, 'RJ7')]),
        ),
        isTrue,
      );
    }
  });

  test(
    'unknown metadata stays unresolved while a known empty tag list is false',
    () {
      final tagQuery = query([condition(SearchType.tag, 'relax')]);
      expect(matchesSearchQuery(work(tags: null), tagQuery), isNull);
      expect(workNeedsSearchMetadata(work(tags: null), tagQuery), isTrue);
      expect(matchesSearchQuery(work(tags: const []), tagQuery), isFalse);

      final ageQuery = query([
        condition(SearchType.keyword, 'quiet'),
      ], ageRating: AgeRating.adult);
      expect(workNeedsSearchMetadata(work(age: '  '), ageQuery), isTrue);
      expect(matchesSearchQuery(work(age: '  '), ageQuery), isNull);

      expect(
        matchesSearchQuery(
          work(title: 'Different title', tags: null),
          query([
            condition(SearchType.keyword, 'quiet'),
            condition(SearchType.tag, 'relax'),
          ]),
        ),
        isFalse,
      );
    },
  );

  test('advanced filters keep fractional rating thresholds', () {
    final atThreshold = query(
      [condition(SearchType.keyword, 'quiet')],
      minRate: 4.25,
      ageRating: AgeRating.general,
      salesRange: SalesRange.over500,
    );
    expect(matchesSearchQuery(work(), atThreshold), isTrue);
    expect(matchesSearchQuery(work(rate: 4.24), atThreshold), isFalse);
    expect(matchesSearchQuery(work(sales: null), atThreshold), isNull);
  });
}
